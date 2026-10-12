import AppKit
import SwiftUI
import SM2FixKit

/// `--snapshots <folder>`: renders the window in each state, light and dark, to PNGs
/// (used by CI to check every window state renders, and for the README screenshot).
enum Snapshots {
    static let folder = URL(fileURLWithPath: "/Volumes/Games/SteamLibrary/steamapps/common/Marvel's Spider-Man 2")
    static let bottles = [
        Bottle(kind: .crossOver, name: "Steam", path: URL(fileURLWithPath: "/tmp/Bottles/Steam")),
        Bottle(kind: .crossOver, name: "Games", path: URL(fileURLWithPath: "/tmp/Bottles/Games")),
    ]

    static func game(bottle: Bottle?, reason: BottleReason?) -> GameInstall {
        GameInstall(folder: folder, bottle: bottle, reason: reason, candidates: bottles)
    }

    static let scenarios: [(String, (AppModel) -> Void)] = [
        ("1-start", { _ in }),
        ("2-ready", { m in
            m.select(game(bottle: bottles[0], reason: .steamLibrary))
            m.status = .notInstalled
        }),
        ("3-applied", { m in
            m.select(game(bottle: bottles[0], reason: .steamLibrary))
            m.status = .installed
            m.banner = AppModel.banner(for: .success(InstallReport(override: .setInFile)), removing: false, bottle: bottles[0])
        }),
        ("4-choose-bottle", { m in
            m.select(game(bottle: nil, reason: nil))
            m.status = .testBuildInstalled
        }),
        ("5-one-more-step", { m in
            m.select(game(bottle: bottles[0], reason: .chosen))
            m.status = .installed
            m.banner = AppModel.banner(for: .failure(InstallError.quitCrossOver), removing: false, bottle: bottles[0])
        }),
        ("6-error", { m in
            m.banner = Banner(kind: .error, title: "That isn't the Spider-Man 2 folder.",
                              detail: "Choose the folder that contains Spider-Man2.exe. In Steam: right-click the game, then Manage › Browse local files.")
        }),
        ("7-choices", { m in
            m.choices = [game(bottle: bottles[0], reason: .steamLibrary),
                         GameInstall(folder: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/CrossOver/Bottles/Games/drive_c/Program Files (x86)/Steam/steamapps/common/Marvel's Spider-Man 2"),
                                     bottle: bottles[1], reason: .insideBottle, candidates: bottles)]
        }),
        ("6b-searching", { m in
            m.busy = true
            m.busyText = "Looking for Spider-Man 2…"
        }),
        ("8-working", { m in
            m.select(game(bottle: bottles[0], reason: .steamLibrary))
            m.status = .updateAvailable
            m.busy = true
            m.busyText = "Applying the fix…"
        }),
    ]

    static func run(into dir: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, setUp) in scenarios {
                let model = AppModel(preview: true)
                setUp(model)
                let ok = render(AnyView(ContentView(model: model)), appearance: appearanceName,
                                to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                if !ok { failures += 1 }
            }
            let ok = render(AnyView(AboutFix(version: "1.0").background(Color(nsColor: .windowBackgroundColor))),
                            appearance: appearanceName, to: dir.appendingPathComponent("9-about-\(suffix).png"))
            if !ok { failures += 1 }
        }
        print("snapshots written to \(dir.path), failures: \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Renders `view` in a real window (so AppKit controls draw) and saves it as PNG.
    static func render(_ view: AnyView, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let app = NSApplication.shared
        // CI can't bring the app to the front, so the default button draws grey here (blue in the real app).
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        let size = host.fittingSize
        window.setContentSize(size)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.display()
        // Always 2x (Retina), whatever the CI display is.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2),
                                         pixelsHigh: Int(host.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            print("\(url.lastPathComponent): \(Int(size.width))x\(Int(size.height)) pt, \(rep.pixelsWide)x\(rep.pixelsHigh) px")
            return true
        } catch {
            print("FAIL \(url.lastPathComponent): \(error)")
            return false
        }
    }
}

