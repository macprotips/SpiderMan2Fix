import Foundation
import XCTest
@testable import SM2FixKit

/// Records commands and answers them: `ps` lists `processes`, wine reg exits with `wineStatus`.
final class FakeRunner: CommandRunner {
    var processes: [String] = []
    var wineStatus: Int32 = 0
    var calls: [(String, [String], [String: String])] = []

    func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) -> CommandResult {
        calls.append((executable.path, arguments, environment))
        if executable.lastPathComponent == "ps" {
            return CommandResult(status: 0, output: processes.joined(separator: "\n"))
        }
        return CommandResult(status: wineStatus, output: "")
    }

    var wineCalls: [[String]] { calls.filter { !$0.0.hasSuffix("/ps") }.map { $0.1 } }
}

/// A fake Mac: a home folder with bottles, a /Volumes folder and an Applications folder.
final class FakeMac {
    let root: URL
    let home: URL
    /// Stands in for /Volumes (external drives).
    let volumes: URL
    let runner = FakeRunner()
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("sm2fix-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        volumes = root.appendingPathComponent("Volumes")
        for dir in [home, volumes] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? fm.removeItem(at: root)
    }

    var env: SystemEnvironment {
        SystemEnvironment(home: home, runner: runner)
    }

    @discardableResult
    func bottle(_ name: String, steam: Bool = true, userReg: String = "WINE REGISTRY Version 2\n",
                base: String = "Library/Application Support/CrossOver/Bottles") throws -> URL {
        let bottle = home.appendingPathComponent(base).appendingPathComponent(name)
        try fm.createDirectory(at: bottle.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bottle.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bottle.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        if steam {
            let steamDir = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
            try fm.createDirectory(at: steamDir.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
            try Data().write(to: steamDir.appendingPathComponent("steam.exe"))
        }
        try userReg.write(to: bottle.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        return bottle
    }

    /// A drive letter in `bottle` pointing at `target`.
    func drive(_ letter: String, in bottle: URL, to target: URL) throws {
        try fm.createSymbolicLink(atPath: bottle.appendingPathComponent("dosdevices/\(letter):").path, withDestinationPath: target.path)
    }

    func libraryVDF(in bottle: URL, paths: [String]) throws {
        var text = "\"libraryfolders\"\n{\n"
        for (i, path) in paths.enumerated() {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            text += "\t\"\(i)\"\n\t{\n\t\t\"path\"\t\t\"\(escaped)\"\n\t\t\"label\"\t\t\"\"\n\t}\n"
        }
        text += "}\n"
        try text.write(to: bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf"),
                       atomically: true, encoding: .utf8)
    }

    /// A game folder. With the shader tools available, its Spider-Man2.exe holds the
    /// stand-in shaders (`StandIns`) the way the real exe holds the game's.
    @discardableResult
    func game(in folder: URL, withShaders: Bool = true) throws -> URL {
        let game = folder.appendingPathComponent("steamapps/common/Marvel's Spider-Man 2")
        try fm.createDirectory(at: game, withIntermediateDirectories: true)
        var exe = GameBuild.minimalExe(timestamp: FakeMac.gameTimestamp, imageSize: 0x0c8d_1000) + Data(repeating: 0x90, count: 4000)
        if withShaders, let standIns = try StandIns.shared() {
            for container in standIns.containers { exe += container + Data(repeating: 0xcc, count: 777) }
        }
        try exe.write(to: game.appendingPathComponent("Spider-Man2.exe"))
        try Data("MZ dstorage".utf8).write(to: game.appendingPathComponent("dstorage.dll"))
        return game
    }

    static let gameTimestamp: UInt32 = 0x6543_2100
    static let gameBuild = "65432100-0c8d1000"

    /// An installer for the stand-in shaders, with the real d3d12.dll and settings.
    func installer() throws -> Installer {
        guard let standIns = try StandIns.shared() else { throw XCTSkip("set SM2FIX_DXC to the folder with dxc, dxa and dxv") }
        return Installer(payload: try payload(), env: env, shaders: standIns.shaders)
    }

    /// The fix's real d3d12.dll from the repository, copied into a temp folder.
    func payload() throws -> Payload {
        guard let tools = StandIns.tools else { throw XCTSkip("set SM2FIX_DXC to the folder with dxc, dxa and dxv") }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("payload")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: repo.appendingPathComponent("prebuilt/fix/d3d12.dll"), to: dir.appendingPathComponent("d3d12.dll"))
        return try Payload(directory: dir, tools: tools)
    }
}

/// Small shaders compiled from HLSL with the same kind of typed pool access as the game's
/// (reads at t1 and t0, and writes through a RWBuffer<uint> at u1 like the symbiote's spline
/// index shaders), standing in for the real ones, which don't ship.
final class StandIns {
    static let tools: URL? = ProcessInfo.processInfo.environment["SM2FIX_DXC"].map { URL(fileURLWithPath: $0) }
    static let sources: [(String, Int32, Bool)] = [
        ("""
        Buffer<uint> pool : register(t1);
        StructuredBuffer<uint> offsets : register(t0);
        RWStructuredBuffer<uint4> result : register(u0);
        [numthreads(64, 1, 1)]
        void main(uint i : SV_DispatchThreadID)
        {
            uint base = offsets[i];
            result[i] = uint4(pool[base], pool[base + 1], pool[base + 2], pool[i + 268435456]);
        }
        """, 1, false),
        ("""
        Buffer<uint> pool : register(t0);
        RWStructuredBuffer<uint> result : register(u0);
        [numthreads(64, 1, 1)]
        void main(uint i : SV_DispatchThreadID) { result[i] = pool[i * 3] ^ pool[i * 3 + 1]; }
        """, 0, false),
        (uavSource, 1, true),
    ]
    /// Fixtures/standin-u1.hlsl: the pool written (and read back) through a typed UAV.
    static let uavSource = """
        RWBuffer<uint> pool : register(u1);
        Buffer<uint> map : register(t1);
        [numthreads(64, 1, 1)]
        void main(uint i : SV_DispatchThreadID)
        {
            uint at = map[i] + 268435456;
            if (pool[at] != 0)
                pool[at + 1] = pool[at] + i;
            pool[i * 3] = (i << 16) | (i + 1);
        }
        """
    private static var cached: StandIns?

    let containers: [Data]
    let shaders: [PoolShader]

    private init(containers: [Data], shaders: [PoolShader]) {
        self.containers = containers
        self.shaders = shaders
    }

    /// nil when the tools aren't available (the tests that need them skip).
    static func shared() throws -> StandIns? {
        if let cached { return cached }
        guard let tools else { return nil }
        let builder = ShaderBuilder(tools: tools)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sm2fix-standins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var containers: [Data] = [], shaders: [PoolShader] = []
        for (i, (source, register, uav)) in sources.enumerated() {
            let hlsl = dir.appendingPathComponent("\(i).hlsl"), dxil = dir.appendingPathComponent("\(i).dxil")
            try source.write(to: hlsl, atomically: true, encoding: .utf8)
            let result = ProcessRunner().run(tools.appendingPathComponent("dxc"), ["-T", "cs_6_6", "-E", "main", "-Fo", dxil.path, hlsl.path],
                                             environment: [:], timeout: 60)
            guard result.status == 0 else { throw ShaderBuildError.toolFailed("dxc", result.output) }
            let container = try Data(contentsOf: dxil)
            let rewritten = try builder.rewrite(container, space: 0, register: register, uav: uav)
            containers.append(container)
            shaders.append(PoolShader(sourceHash: shaderHash(container), space: 0, register: register, uav: uav,
                                      resultHash: shaderHash(rewritten)))
        }
        cached = StandIns(containers: containers, shaders: shaders)
        return cached
    }
}
