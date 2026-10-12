import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What the app carries: the fix's d3d12.dll and Microsoft's shader tools. The rewritten
/// shaders are built from the user's own game, so none ship with it.
public struct Payload {
    public let dll: URL
    /// Folder with dxc, dxa and dxv.
    public let tools: URL

    public enum LoadError: Error, LocalizedError {
        case missing(String)
        public var errorDescription: String? {
            switch self {
            case .missing(let name): return "The app is missing its \(name). Download it again."
            }
        }
    }

    /// Loads the payload from a folder holding d3d12.dll, with the shader tools in `tools`.
    public init(directory: URL, tools: URL) throws {
        let dllFile = directory.appendingPathComponent("d3d12.dll")
        guard FileManager.default.fileExists(atPath: dllFile.path) else { throw LoadError.missing("d3d12.dll") }
        guard ShaderBuilder(tools: tools).toolsPresent else { throw LoadError.missing("shader tools") }
        dll = dllFile
        self.tools = tools
    }
}

/// Which build of the game an exe is: its PE timestamp and image size. The fix's
/// d3d12.dll reads the same two fields from the running game and only acts when they
/// match what the app wrote to sm2fix.ini.
public enum GameBuild {
    public static func of(exe: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 64 else { return nil }
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= head.count else { return nil }
            return head[head.startIndex + at ..< head.startIndex + at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard head.prefix(2) == Data("MZ".utf8), let pe = u32(0x3c).map(Int.init),
              u32(pe) == 0x0000_4550,                       // "PE\0\0"
              let timestamp = u32(pe + 8), let imageSize = u32(pe + 24 + 56) else { return nil }
        return hex8(timestamp) + "-" + hex8(imageSize)
    }

    static func hex8(_ v: UInt32) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: 8 - s.count) + s
    }

    /// The smallest file `of(exe:)` reads (tests and the app's self-test).
    public static func minimalExe(timestamp: UInt32, imageSize: UInt32) -> Data {
        var d = Data(count: 0x200)
        func put(_ v: UInt32, _ at: Int) { for i in 0..<4 { d[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) } }
        d[0] = 0x4d; d[1] = 0x5a                            // "MZ"
        put(0x80, 0x3c)
        put(0x0000_4550, 0x80)                              // "PE\0\0"
        put(timestamp, 0x80 + 8)
        put(0x20b, 0x80 + 24)                               // PE32+
        put(imageSize, 0x80 + 24 + 56)
        return d
    }
}

/// Whether the fix is in a game folder.
public enum FixStatus: Equatable {
    case notInstalled
    case installed
    /// This fix, but an older version of it.
    case updateAvailable
    /// Set up for an earlier build of the game; the fix does nothing until updated.
    case gameUpdated
    /// One of the earlier troubleshooting test builds.
    case testBuildInstalled
}

public enum InstallError: Error, LocalizedError, Equatable {
    case notAGameFolder
    case gameRunning
    case quitCrossOver
    case readOnly(String)
    case copyFailed(String)
    case shaders(ShaderBuildError)

    public var errorDescription: String? {
        switch self {
        case .notAGameFolder:
            return "That folder doesn't contain Spider-Man2.exe."
        case .gameRunning:
            return "Quit Spider-Man 2, then click the button again. Nothing was changed."
        case .quitCrossOver:
            return "Then click the button again. Nothing was changed. If you still see this, restart your Mac."
        case .readOnly(let path):
            return "Can't write to \(path). If the game is on an external drive formatted as NTFS, macOS can only read it."
        case .copyFailed(let reason):
            return "Couldn't copy the fix into the game folder: \(reason)"
        case .shaders(let error):
            return error.errorDescription
        }
    }
}

/// What an install or removal did, for showing to the user.
public struct InstallReport: Equatable {
    public var override: DllOverride.Outcome?
    public var notes: [String] = []

    public init(override: DllOverride.Outcome? = nil, notes: [String] = []) {
        self.override = override
        self.notes = notes
    }
}

public struct Installer {
    public let payload: Payload
    public let env: SystemEnvironment
    public let shaders: [PoolShader]

    public init(payload: Payload, env: SystemEnvironment, shaders: [PoolShader] = PoolShader.spiderMan2) {
        self.payload = payload
        self.env = env
        self.shaders = shaders
    }

    static let managedFiles = ["d3d12.dll", "sm2fix.ini", "sm2fix.log", "sm2fix-skinning.dxil"]
    static let managedFolders = ["sm2fix-dumps", "sm2fix-capture"]
    static let backupSuffix = ".sm2fix-backup"

    static func isShim(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("sm2fix".utf8)) != nil
    }

    static func iniValue(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }

    public func status(of folder: URL) -> FixStatus {
        let dll = folder.appendingPathComponent("d3d12.dll")
        guard Self.isShim(dll) else { return .notInstalled }
        let ini = (try? String(contentsOf: folder.appendingPathComponent("sm2fix.ini"), encoding: .utf8)) ?? ""
        guard let build = Self.iniValue("game_build", in: ini) else {
            // an earlier version of the fix (pool_fix = 1), or a troubleshooting test
            return Self.iniValue("pool_fix", in: ini) == "1" ? .updateAvailable : .testBuildInstalled
        }
        if build != GameBuild.of(exe: folder.appendingPathComponent(GameFinder.exeName)) { return .gameUpdated }
        let fm = FileManager.default
        let sameDll = fm.contentsEqual(atPath: dll.path, andPath: payload.dll.path)
        let sameShaders = shaders.allSatisfy { shader in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(shader.fileName)) else { return false }
            return shader.resultHash.map { shaderHash(data) == $0 } ?? true
        }
        let sameList = Self.iniValue("shaders", in: ini) == shaders.map { hex($0.sourceHash) }.joined(separator: " ")
        return sameDll && sameShaders && sameList ? .installed : .updateAvailable
    }

    /// sm2fix.ini: which game build the fix was set up for, and its shaders.
    func settings(gameBuild: String) -> String {
        """
        # Spider-Man 2 T-Pose Fix, written by the app. The fix only acts on this game build.
        game_build = \(gameBuild)
        shaders = \(shaders.map { hex($0.sourceHash) }.joined(separator: " "))

        """
    }

    func readUserReg(_ bottle: Bottle) -> String {
        (try? String(contentsOf: bottle.userReg, encoding: .utf8)) ?? ""
    }

    /// A d3d12.dll the fix put aside when it was installed (it goes back on removal).
    func hasOtherD3D12(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("d3d12.dll" + Self.backupSuffix).path)
    }

    func checkWritable(_ folder: URL) throws {
        guard GameFinder.hasExe(folder) else { throw InstallError.notAGameFolder }
        if env.gameIsRunning() { throw InstallError.gameRunning }
        let probe = folder.appendingPathComponent(".sm2fix-write-test")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else {
            throw InstallError.readOnly(folder.path)
        }
        try? FileManager.default.removeItem(at: probe)
    }

    static func replace(_ destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) || (try? destination.checkResourceIsReachable()) == true {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        #if canImport(Darwin)
        removexattr(destination.path, "com.apple.quarantine", 0)
        #endif
    }

    /// Installs (or updates) the fix in `game.folder` and sets the DLL override in its bottle.
    /// The shaders are built from the game's own Spider-Man2.exe first; nothing in the game
    /// folder changes unless that works.
    public func install(_ game: GameInstall) throws -> InstallReport {
        let folder = game.folder
        try checkWritable(folder)
        let fm = FileManager.default
        var report = InstallReport()
        if let bottle = game.bottle, !DllOverride.isSet(inUserReg: readUserReg(bottle)), env.wineIsRunning() {
            throw InstallError.quitCrossOver
        }
        guard let gameBuild = GameBuild.of(exe: folder.appendingPathComponent(GameFinder.exeName)) else {
            throw InstallError.shaders(.cantReadGame("it isn't a Windows program"))
        }
        let built: [String: Data]
        do {
            built = try ShaderBuilder(tools: payload.tools)
                .build(shaders, fromGame: folder.appendingPathComponent(GameFinder.exeName))
        } catch let error as ShaderBuildError {
            throw InstallError.shaders(error)
        }

        let dll = folder.appendingPathComponent("d3d12.dll")
        let backup = folder.appendingPathComponent("d3d12.dll" + Self.backupSuffix)
        if fm.fileExists(atPath: dll.path), !Self.isShim(dll), !fm.fileExists(atPath: backup.path) {
            do {
                try fm.moveItem(at: dll, to: backup)
                report.notes.append("Your game folder already had a d3d12.dll; it was kept as d3d12.dll\(Self.backupSuffix).")
            } catch {
                throw InstallError.copyFailed(error.localizedDescription)
            }
        }
        do {
            // Leftovers from the troubleshooting tests.
            for name in Self.managedFiles + Self.managedFolders where name != "d3d12.dll" {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
            for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("sm2fix-pool-") && old.pathExtension == "dxil" {
                try? fm.removeItem(at: old)
            }
            try Self.replace(dll, with: payload.dll)
            for (name, data) in built.sorted(by: { $0.key < $1.key }) {
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            try settings(gameBuild: gameBuild).write(to: folder.appendingPathComponent("sm2fix.ini"), atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }

        // DirectStorage switched off by an earlier test: switch it back on.
        for name in ["dstorage.dll", "dstoragecore.dll"] {
            let off = folder.appendingPathComponent(name + ".sm2fix-off")
            let on = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: off.path), !fm.fileExists(atPath: on.path) {
                try? fm.moveItem(at: off, to: on)
            }
        }

        if let bottle = game.bottle {
            report.override = DllOverride.ensure(in: bottle, env: env)
        }
        return report
    }

    /// Removes the fix from `game.folder`, puts back a d3d12.dll it replaced, and removes
    /// the DLL override when nothing needs it any more.
    public func uninstall(_ game: GameInstall) throws -> InstallReport {
        let folder = game.folder
        try checkWritable(folder)
        if let bottle = game.bottle, !hasOtherD3D12(folder), DllOverride.isSet(inUserReg: readUserReg(bottle)),
           env.wineIsRunning() {
            throw InstallError.quitCrossOver
        }
        let fm = FileManager.default
        var report = InstallReport()
        let dll = folder.appendingPathComponent("d3d12.dll")
        do {
            if fm.fileExists(atPath: dll.path), Self.isShim(dll) { try fm.removeItem(at: dll) }
            for name in Self.managedFiles + Self.managedFolders where name != "d3d12.dll" {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
            for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("sm2fix-pool-") && old.pathExtension == "dxil" {
                try fm.removeItem(at: old)
            }
            let backup = folder.appendingPathComponent("d3d12.dll" + Self.backupSuffix)
            if fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: dll.path) {
                try fm.moveItem(at: backup, to: dll)
                report.notes.append("Put back the d3d12.dll your game folder had before.")
            }
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }
        if let bottle = game.bottle, !fm.fileExists(atPath: dll.path) {
            report.override = DllOverride.remove(from: bottle, env: env)
        }
        return report
    }
}
