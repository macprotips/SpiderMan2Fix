import Foundation

/// A CrossOver bottle on this Mac.
public struct Bottle: Hashable, Identifiable {
    public enum Kind: String {
        case crossOver = "CrossOver"
    }

    public let kind: Kind
    public let name: String
    public let path: URL

    public init(kind: Kind, name: String, path: URL) {
        self.kind = kind
        self.name = name
        self.path = path
    }

    public var id: String { path.path }
    public var displayName: String { "\(kind.rawValue) bottle “\(name)”" }
    public var userReg: URL { path.appendingPathComponent("user.reg") }

    /// Whether Steam is installed inside this bottle.
    public var hasSteam: Bool {
        let fm = FileManager.default
        return Self.steamFolders.contains {
            fm.fileExists(atPath: path.appendingPathComponent("drive_c/\($0)/steam.exe").path)
        }
    }

    static let steamFolders = ["Program Files (x86)/Steam", "Program Files/Steam"]

    /// Where Windows path `windowsPath` (like `K:\SteamLibrary`) is on the Mac, using the
    /// bottle's drive-letter links in `dosdevices`.
    public func macURL(forWindowsPath windowsPath: String) -> URL? {
        let chars = Array(windowsPath)
        guard chars.count >= 2, chars[1] == ":", chars[0].isLetter else { return nil }
        let letter = String(chars[0]).lowercased()
        let drive = path.appendingPathComponent("dosdevices/\(letter):").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        let rest = String(chars.dropFirst(2)).replacingOccurrences(of: "\\", with: "/")
        let parts = rest.split(separator: "/").map(String.init)
        return parts.reduce(drive) { $0.appendingPathComponent($1) }
    }

    /// The Steam library folders this bottle's Steam knows about, as Mac paths.
    public func steamLibraries() -> [URL] {
        var libraries: [URL] = []
        for folder in Self.steamFolders {
            for list in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
                let vdf = path.appendingPathComponent("drive_c/\(folder)/\(list)")
                guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
                for windowsPath in Self.libraryPaths(inVDF: text) {
                    if let url = macURL(forWindowsPath: windowsPath),
                       !libraries.contains(where: { $0.canonicalPath == url.canonicalPath }) {
                        libraries.append(url)
                    }
                }
            }
        }
        return libraries
    }

    /// Mac folders this bottle has drive letters for, other than its own C: and the
    /// whole-Mac Z: (/).
    public func mappedDrives() -> [URL] {
        let links = (try? FileManager.default.contentsOfDirectory(at: path.appendingPathComponent("dosdevices"),
                                                                 includingPropertiesForKeys: nil)) ?? []
        return links.filter { $0.lastPathComponent.count == 2 && $0.lastPathComponent.hasSuffix(":") }
            .map { $0.resolvingSymlinksInPath() }
            .filter { target in
                target.canonicalPath != "/" && !target.isInside(path)
                    && FileManager.default.fileExists(atPath: target.path)
            }
    }

    /// Whether Spider-Man 2 has per-game Wine settings in this bottle (the fix, or the
    /// troubleshooting menu, set them up here before).
    public var hasGameSettings: Bool {
        guard let text = try? String(contentsOf: userReg, encoding: .utf8) else { return false }
        return text.range(of: "AppDefaults\\\\\(GameFinder.exeName)", options: .caseInsensitive) != nil
    }

    /// The `"path"` entries of a Steam `libraryfolders.vdf`, unescaped.
    public static func libraryPaths(inVDF text: String) -> [String] {
        var paths: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"path\"") else { continue }
            let rest = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") else { continue }
            let value = String(rest.dropFirst().dropLast()).replacingOccurrences(of: "\\\\", with: "\\")
            paths.append(value)
        }
        return paths
    }
}

/// Why a bottle was picked for the game.
public enum BottleReason: String, Equatable {
    case insideBottle = "The game is inside this bottle."
    case steamLibrary = "This bottle's Steam has the game's library."
    case gameSettings = "The game was set up in this bottle before."
    case driveLetter = "This bottle has a drive letter for the game's disk."
    case onlySteam = "The only bottle with Steam installed."
    case chosen = "Chosen by you."
}

public enum Bottles {
    /// Every CrossOver bottle in the user's home folder.
    public static func all(in env: SystemEnvironment) -> [Bottle] {
        let root = env.home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }.compactMap { entry in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.appendingPathComponent("drive_c").path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return Bottle(kind: .crossOver, name: entry.lastPathComponent, path: entry)
        }
    }

    /// Which bottle runs the game in `gameFolder`, and why. Each test narrows the bottles
    /// down; the first that leaves exactly one decides:
    /// the bottle the game is inside; bottles whose Steam lists the game's library; bottles
    /// where the game has Wine settings already; bottles with a drive letter for the
    /// game's disk; bottles with Steam installed.
    public static func bottle(for gameFolder: URL, among bottles: [Bottle]) -> (bottle: Bottle?, reason: BottleReason?) {
        if let inside = bottles.first(where: { gameFolder.isInside($0.path) }) {
            return (inside, .insideBottle)
        }
        var pool = bottles
        let tests: [(BottleReason, (Bottle) -> Bool)] = [
            (.steamLibrary, { $0.steamLibraries().contains { gameFolder.isInside($0) } }),
            (.gameSettings, { $0.hasGameSettings }),
            (.driveLetter, { $0.mappedDrives().contains { gameFolder.isInside($0) } }),
            (.onlySteam, { $0.hasSteam }),
        ]
        for (reason, test) in tests {
            let matching = pool.filter(test)
            if matching.count == 1 { return (matching[0], reason) }
            if matching.count > 1 { pool = matching }
        }
        return (nil, nil)
    }
}
