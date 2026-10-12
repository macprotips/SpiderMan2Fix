import AppKit
import SwiftUI
import SM2FixKit

/// Layout constants, so every card, row and edge lines up.
enum Metrics {
    static let windowWidth: CGFloat = 560
    static let edge: CGFloat = 24
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let labelWidth: CGFloat = 56
}

enum Brand {
    static let red = Color(red: 0.80, green: 0.13, blue: 0.20)
    static let navy = Color(red: 0.16, green: 0.17, blue: 0.40)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false
    /// The CrossOver support note is shown once, on the first launch.
    @AppStorage("shownBottleSupportNote") private var shownSupportNote = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Header(version: model.version)
                content
                if let banner = model.banner {
                    BannerView(banner: banner)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, Metrics.edge)
            .padding(.top, 22)
            .padding(.bottom, Metrics.edge)

            if model.game != nil {
                Divider()
                FooterBar(model: model)
                    .padding(.horizontal, Metrics.edge)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: Metrics.windowWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if dropTargeted && model.game != nil {
                DropOverlay()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .animation(.easeInOut(duration: 0.2), value: model.game)
        .onAppear { model.searchAtLaunch() }
        .alert("Before you start", isPresented: Binding(get: { !shownSupportNote }, set: { if !$0 { shownSupportNote = true } })) {
            Button("OK") { shownSupportNote = true }
        } message: {
            Text("This fix changes a setting in your CrossOver bottle. CodeWeavers can't support CrossOver while the fix is applied. Before contacting CrossOver support, click Remove Fix to put the bottle back as it was.")
        }
    }

    @ViewBuilder private var content: some View {
        if let game = model.game {
            GameCard(model: model, game: game)
        } else if !model.choices.isEmpty {
            ChoiceList(model: model)
        } else {
            DropZone(model: model, targeted: dropTargeted)
        }
    }
}

// MARK: - Header

struct Header: View {
    let version: String
    @State private var showInfo = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Spacer(minLength: 0)
                Text("Spider-Man 2 T-Pose Fix")
                    .font(.system(size: 20, weight: .semibold))
                Text("Fixes the T-pose and the symbiote in Marvel's Spider-Man 2 on Macs with an M1, M2, M3 or M4 chip.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 64)
            Spacer(minLength: 0)
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("How it works")
            .accessibilityLabel("How it works")
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                AboutFix(version: version)
            }
        }
    }
}

// MARK: - Card

/// The rounded, bordered container used for the game, the drop zone and the choice list.
struct Card<Content: View>: View {
    var dashed = false
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor : Color(nsColor: .separatorColor),
                                  style: StrokeStyle(lineWidth: highlighted ? 2 : 1, dash: dashed ? [6, 4] : []))
            )
    }
}

struct GameCard: View {
    @ObservedObject var model: AppModel
    let game: GameInstall

    var body: some View {
        Card {
            VStack(spacing: 0) {
                gameRow
                Divider().padding(.leading, Metrics.cardPadding)
                bottleRow
                Divider().padding(.leading, Metrics.cardPadding)
                statusRow
            }
            .padding(.bottom, 5)
        }
    }

    private var gameRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Brand.red, Brand.navy], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(GameFinder.folderName)
                    .font(.system(size: 13, weight: .semibold))
                Text(game.folder.deletingLastPathComponent().abbreviatedPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(game.folder.path)
            }
            Spacer(minLength: 12)
            Button {
                model.showInFinder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
            Button("Change…") { model.forget() }
                .disabled(model.busy)
        }
        .padding(Metrics.cardPadding)
    }

    private var bottleRow: some View {
        CardRow(label: "Bottle") {
            if model.bottles.isEmpty {
                Text("No CrossOver bottles found")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Bottle", selection: Binding(get: { model.bottleID }, set: { model.choose(bottleID: $0) })) {
                        if model.bottleID == nil {
                            Text("Choose…").tag(String?.none)
                        }
                        ForEach(model.bottles) { bottle in
                            Text("\(bottle.name) (\(bottle.kind.rawValue))").tag(Optional(bottle.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.busy)
                    if model.selectedBottle == nil {
                        Label("Choose the bottle you run Steam in.", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else if let reason = model.bottleReason {
                        Text(reason.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusRow: some View {
        CardRow(label: "Status") {
            StatusView(status: model.status)
        }
    }
}

/// A labelled row inside a card: label column on the left, content on the right.
struct CardRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 12)
    }
}

struct StatusView: View {
    let status: FixStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch status {
        case .installed?: return "Fix installed"
        case .updateAvailable?: return "Update available"
        case .gameUpdated?: return "The game was updated"
        case .testBuildInstalled?: return "Troubleshooting test installed"
        case .notInstalled?: return "Not installed"
        case nil: return "Checking…"
        }
    }

    private var detail: String? {
        switch status {
        case .installed?: return "Start the game as usual."
        case .updateAvailable?: return "This app has a newer version of the fix."
        case .gameUpdated?: return "The fix is paused until it's updated for this version of the game."
        case .testBuildInstalled?: return "Apply Fix replaces it with the finished fix."
        default: return nil
        }
    }

    private var color: Color {
        switch status {
        case .installed?: return .green
        case .updateAvailable?, .gameUpdated?, .testBuildInstalled?: return .orange
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - Drop zone and choices

struct DropZone: View {
    @ObservedObject var model: AppModel
    let targeted: Bool

    var body: some View {
        Card(dashed: true, highlighted: targeted) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    .padding(.bottom, 2)
                Text("Drop the Marvel's Spider-Man 2 folder here")
                    .font(.system(size: 15, weight: .semibold))
                Text("It's the folder with Spider-Man2.exe inside. In Steam, right-click the game and choose Manage › Browse local files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                Group {
                    if model.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.busyText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 10) {
                            Button("Choose Folder…") { model.chooseFolder() }
                            Button("Find Automatically") { model.findAutomatically() }
                        }
                    }
                }
                .frame(height: 24)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, Metrics.cardPadding)
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

struct ChoiceList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spider-Man 2 is in more than one place. Which one do you play?")
                .font(.system(size: 13, weight: .semibold))
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(model.choices.enumerated()), id: \.element.folder) { index, install in
                        if index > 0 { Divider().padding(.leading, Metrics.cardPadding) }
                        ChoiceRow(install: install) { model.select(install) }
                    }
                }
            }
            Button("Choose a Different Folder…") { model.chooseFolder() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }
}

struct ChoiceRow: View {
    let install: GameInstall
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(install.folder.abbreviatedPath)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(install.bottle.map { "\($0.name) (\($0.kind.rawValue))" } ?? "Bottle not known yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .light))
                Text("Drop to use this folder")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 3))
        .allowsHitTesting(false)
    }
}

// MARK: - Banner

struct BannerView: View {
    let banner: Banner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                if !banner.detail.isEmpty {
                    Text(banner.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.30)))
    }

    private var color: Color {
        switch banner.kind {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var symbol: String {
        switch banner.kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView()
                    .controlSize(.small)
                Text(model.busyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.game != nil {
                if let status = model.status, status != .notInstalled {
                    Button("Remove Fix", action: model.remove)
                        .controlSize(.large)
                        .disabled(model.busy)
                }
                Button(action: model.apply) {
                    Text(applyTitle).frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canApply)
            }
        }
        .frame(minHeight: 32)
    }

    private var applyTitle: String {
        switch model.status {
        case .installed?: return "Reinstall"
        case .updateAvailable?, .gameUpdated?: return "Update Fix"
        default: return "Apply Fix"
        }
    }
}

struct AboutFix: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works")
                .font(.system(size: 13, weight: .semibold))
            Text("On M1 to M4 Macs, the graphics layer returns zeros when a shader reads a “typed” buffer past its 268,435,456th element, and loses writes there. Spider-Man 2 keeps every character's mesh in one 2 GB buffer used exactly that way. Characters stored in its upper half never get animated, so they stay in a T-pose. The game also builds the symbiote there every frame, so it shows up as spikes, a flat black sheet, or not at all.")
            Text("The fix puts a small d3d12.dll and four rewritten shaders in the game folder so the game reads and writes that buffer the “raw” way, which works to the end, and tells Wine to load it. The game and CrossOver themselves aren't changed, and Remove Fix undoes everything.")
            Divider().padding(.vertical, 2)
            HStack {
                Link("Source code and details",
                     destination: URL(string: "https://github.com/macprotips/SpiderMan2Fix")!)
                Spacer()
                Text("Version \(version)")
                    .foregroundStyle(.secondary)
            }
            Text("Not affiliated with Sony Interactive Entertainment, Insomniac Games or Marvel.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 360)
        .padding(16)
    }
}

extension URL {
    /// The path with the home folder shown as ~.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
