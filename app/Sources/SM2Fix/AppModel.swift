import AppKit
import Foundation
import SM2FixKit

/// A message shown under the game card.
struct Banner: Equatable {
    enum Kind { case success, warning, error }
    var kind: Kind
    var title: String
    var detail: String = ""
}

/// The app's state. All the work happens in SM2FixKit, off the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var game: GameInstall?
    @Published var bottleID: String?
    @Published var bottleReason: BottleReason?
    @Published var status: FixStatus?
    @Published var busy = false
    @Published var busyText = ""
    @Published var banner: Banner?
    /// More than one copy of the game was found: the user picks one.
    @Published var choices: [GameInstall] = []

    let env = SystemEnvironment()
    let payload: Result<Payload, Error>
    /// Screenshots: no searching, no disk access.
    let isPreview: Bool
    private let queue = DispatchQueue(label: "sm2fix.work", qos: .userInitiated)
    private var searchedAtLaunch = false
    private static let rememberedKey = "BottleForGameFolder"

    init(preview: Bool = false) {
        isPreview = preview
        payload = Result { try AppModel.loadPayload() }
        if !preview, case .failure(let error) = payload {
            banner = Banner(kind: .error, title: "This copy of the app is incomplete.", detail: error.localizedDescription)
        }
    }

    static func loadPayload() throws -> Payload {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        return try Payload(directory: resources.appendingPathComponent("payload"),
                           tools: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers"))
    }

    var bottles: [Bottle] { game?.candidates ?? [] }

    var selectedBottle: Bottle? {
        bottles.first { $0.id == bottleID }
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Apply needs a bottle, unless there are no bottles at all (then it explains the manual step).
    var canApply: Bool {
        game != nil && !busy && (selectedBottle != nil || bottles.isEmpty)
    }

    // MARK: - Finding the game

    /// Looks for the game once at launch, and picks it if there's exactly one copy.
    func searchAtLaunch() {
        guard !isPreview, !searchedAtLaunch, game == nil else { return }
        searchedAtLaunch = true
        findAutomatically(quiet: true)
    }

    func findAutomatically(quiet: Bool = false) {
        busy = true
        busyText = "Looking for Spider-Man 2…"
        banner = nil
        let env = self.env
        queue.async {
            let found = GameFinder.findAll(env: env)
            DispatchQueue.main.async {
                self.busy = false
                if found.count == 1 {
                    self.select(found[0])
                } else if found.count > 1 {
                    self.choices = found
                } else if !quiet {
                    self.banner = Banner(kind: .warning, title: "Couldn't find Spider-Man 2 automatically.",
                                         detail: "Drag the Marvel's Spider-Man 2 folder into this window, or click Choose Folder.")
                }
            }
        }
    }

    /// Something dropped on the window or the app icon, or picked in the open panel.
    func open(_ url: URL) {
        busy = true
        busyText = "Checking \(url.lastPathComponent)…"
        banner = nil
        let env = self.env
        queue.async {
            let folder = GameFinder.gameFolder(from: url)
            let install = folder.map { GameFinder.install(at: $0, env: env) }
            DispatchQueue.main.async {
                self.busy = false
                if let install {
                    self.select(install)
                } else {
                    self.banner = Banner(kind: .error, title: "That isn't the Spider-Man 2 folder.",
                                         detail: "Choose the folder that contains Spider-Man2.exe. In Steam: right-click the game, then Manage › Browse local files.")
                }
            }
        }
    }

    /// Looks at the bottles again, after adding one or moving CrossOver's bottles folder.
    func refreshBottles() {
        if let game { open(game.folder) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Marvel's Spider-Man 2 Folder"
        panel.message = "Choose the folder that contains Spider-Man2.exe."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func select(_ install: GameInstall) {
        choices = []
        game = install
        let remembered = (UserDefaults.standard.dictionary(forKey: Self.rememberedKey) as? [String: String])?[install.folder.path]
        if install.reason == .insideBottle || remembered == nil
            || !install.candidates.contains(where: { $0.id == remembered }) {
            bottleID = install.bottle?.id
            bottleReason = install.reason
        } else {
            bottleID = remembered
            bottleReason = remembered == install.bottle?.id ? install.reason : .chosen
        }
        refreshStatus()
    }

    /// The user picked a bottle: remember it for this game folder.
    func choose(bottleID id: String?) {
        bottleID = id
        bottleReason = id == nil ? nil : (id == game?.bottle?.id ? game?.reason : .chosen)
        guard let game, let id, !isPreview else { return }
        var remembered = UserDefaults.standard.dictionary(forKey: Self.rememberedKey) as? [String: String] ?? [:]
        remembered[game.folder.path] = id
        UserDefaults.standard.set(remembered, forKey: Self.rememberedKey)
    }

    func forget() {
        game = nil
        status = nil
        banner = nil
        choices = []
    }

    func refreshStatus() {
        guard !isPreview, let game, case .success(let payload) = payload else { return }
        status = Installer(payload: payload, env: env).status(of: game.folder)
    }

    // MARK: - Installing

    func apply() { run(remove: false) }
    func remove() { run(remove: true) }

    private func run(remove: Bool) {
        guard var game, case .success(let payload) = payload else { return }
        game.bottle = selectedBottle
        busy = true
        busyText = remove ? "Removing the fix…" : "Building the fix from your copy of the game…"
        banner = nil
        let installer = Installer(payload: payload, env: env)
        queue.async {
            let result = Result { try remove ? installer.uninstall(game) : installer.install(game) }
            DispatchQueue.main.async {
                self.busy = false
                self.refreshStatus()
                self.banner = Self.banner(for: result, removing: remove, bottle: game.bottle)
            }
        }
    }

    static func banner(for result: Result<InstallReport, Error>, removing: Bool, bottle: Bottle?) -> Banner {
        let report: InstallReport
        switch result {
        case .failure(InstallError.gameRunning):
            return Banner(kind: .warning, title: "Quit Spider-Man 2 first", detail: InstallError.gameRunning.localizedDescription)
        case .failure(InstallError.quitCrossOver):
            return Banner(kind: .warning, title: "Quit Steam and CrossOver", detail: InstallError.quitCrossOver.localizedDescription)
        case .failure(let error):
            return Banner(kind: .error, title: removing ? "Couldn't remove the fix." : "Couldn't apply the fix.",
                          detail: error.localizedDescription)
        case .success(let r):
            report = r
        }
        var notes = report.notes
        let manual = "In CrossOver, select the bottle, open Wine Configuration › Libraries, add d3d12 and set it to “Native then Builtin”."
        if removing {
            return Banner(kind: .success, title: "The fix was removed.",
                          detail: (["The game is back to how it was."] + notes).joined(separator: " "))
        }
        switch report.override {
        case .failed(let reason)?:
            notes.insert("The fix is in the game folder, but Wine couldn't be set to load it (\(reason)). Do it once by hand: \(manual)", at: 0)
            return Banner(kind: .warning, title: "One more step", detail: notes.joined(separator: " "))
        case .wineRunning?:
            notes.insert("Quit CrossOver, then click Apply Fix again.", at: 0)
            return Banner(kind: .warning, title: "One more step", detail: notes.joined(separator: " "))
        case nil:
            notes.insert("No CrossOver bottle was found, so Wine wasn't set to load it. If the fix doesn't take effect: \(manual)", at: 0)
            return Banner(kind: .warning, title: "The fix was copied", detail: notes.joined(separator: " "))
        default:
            notes.insert("Start Spider-Man 2 from CrossOver as usual.", at: 0)
            return Banner(kind: .success, title: "The fix is applied.", detail: notes.joined(separator: " "))
        }
    }

    func showInFinder() {
        guard let game else { return }
        NSWorkspace.shared.activateFileViewerSelecting([game.folder.appendingPathComponent(GameFinder.exeName)])
    }
}
