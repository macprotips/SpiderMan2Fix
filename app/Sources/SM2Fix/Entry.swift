import AppKit
import SwiftUI
import SM2FixKit

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            exit(SelfTest.run())
        }
        if let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count {
            exit(Snapshots.run(into: URL(fileURLWithPath: args[i + 1])))
        }
        SM2FixApp.main()
    }
}

struct SM2FixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Spider-Man 2 T-Pose Fix", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Link("Spider-Man 2 T-Pose Fix Help",
                     destination: URL(string: "https://github.com/macprotips/SpiderMan2Fix")!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A folder dropped on the app's icon (Dock or Finder).
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            AppModel.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// `--selftest`: checks the bundled files and tools, then does a full install/remove round
/// trip in a temporary folder. The bundled dxc compiles a small stand-in shader with the
/// same kind of typed pool read, which goes into a fake Spider-Man2.exe and is rewritten
/// like the real ones. Used by CI on the built app.
enum SelfTest {
    static let standIn = """
    Buffer<uint> pool : register(t1);
    RWStructuredBuffer<uint> result : register(u0);
    [numthreads(64, 1, 1)]
    void main(uint i : SV_DispatchThreadID) { result[i] = pool[i * 3] + pool[i + 268435456]; }
    """
    /// Writes the pool through a typed UAV like the symbiote's spline index shaders.
    static let standInUAV = """
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

    static func run() -> Int32 {
        do {
            let payload = try AppModel.loadPayload()
            print("payload: \(payload.dll.path)")
            print("tools: \(payload.tools.path)")
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("sm2fix-selftest-\(UUID().uuidString)")
            let game = work.appendingPathComponent("game")
            try fm.createDirectory(at: game, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }

            var exe = GameBuild.minimalExe(timestamp: 0x6543_2100, imageSize: 0x0c8d_1000) + Data(repeating: 0x90, count: 4000)
            var shaders: [PoolShader] = []
            for (name, source, uav) in [("standin", standIn, false), ("standin-uav", standInUAV, true)] {
                let hlsl = work.appendingPathComponent(name + ".hlsl"), dxil = work.appendingPathComponent(name + ".dxil")
                try source.write(to: hlsl, atomically: true, encoding: .utf8)
                let compiled = ProcessRunner().run(payload.tools.appendingPathComponent("dxc"),
                                                   ["-T", "cs_6_6", "-E", "main", "-Fo", dxil.path, hlsl.path], environment: [:], timeout: 60)
                guard compiled.status == 0 else {
                    print("FAIL: dxc: \(compiled.output)")
                    return 1
                }
                let container = try Data(contentsOf: dxil)
                exe += container + Data(repeating: 0xcc, count: 1000)
                shaders.append(PoolShader(sourceHash: shaderHash(container), space: 0, register: 1, uav: uav, resultHash: nil))
            }
            try exe.write(to: game.appendingPathComponent(GameFinder.exeName))

            let installer = Installer(payload: payload, env: SystemEnvironment(), shaders: shaders)
            let install = GameInstall(folder: game, bottle: nil, candidates: [])
            _ = try installer.install(install)
            guard installer.status(of: game) == .installed else {
                print("FAIL: status after install is \(installer.status(of: game))")
                return 1
            }
            for shader in shaders {
                let built = game.appendingPathComponent(shader.fileName), listing = work.appendingPathComponent("built.ll")
                _ = ProcessRunner().run(payload.tools.appendingPathComponent("dxc"), ["-dumpbin", built.path, "-Fc", listing.path],
                                        environment: [:], timeout: 60)
                let text = (try? String(contentsOf: listing, encoding: .utf8)) ?? ""
                if shader.uav {
                    guard text.contains("@dx.op.rawBufferStore.i32"), !text.contains("@dx.op.bufferStore.i32(") else {
                        print("FAIL: the rebuilt UAV shader still writes the pool typed")
                        return 1
                    }
                    print("rebuilt stand-in shader: \(shader.fileName), raw pool writes only")
                } else {
                    guard text.contains("@dx.op.rawBufferLoad.i32"), !text.contains("@dx.op.bufferLoad.i32(") else {
                        print("FAIL: the rebuilt shader still reads the pool typed")
                        return 1
                    }
                    print("rebuilt stand-in shader: \(shader.fileName), raw loads only")
                }
            }
            _ = try installer.uninstall(install)
            guard installer.status(of: game) == .notInstalled else {
                print("FAIL: status after removal is \(installer.status(of: game))")
                return 1
            }
            print("selftest ok")
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }
}
