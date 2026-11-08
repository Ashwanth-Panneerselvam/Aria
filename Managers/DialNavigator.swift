import Foundation
import Combine

/// One row in a dial-mode menu.
struct DialItem {
    enum Action {
        /// Builds the next menu when selected (lazy, so big lists cost
        /// nothing until opened).
        case submenu(() -> DialMenu)
        /// Plays `tracks` from `index` and shows Now Playing.
        case play(tracks: [Track], index: Int)
        case nowPlaying
        case perform(() -> DialOutcome)
    }

    let title: String
    var detail: String?
    var action: Action

    var opensSomething: Bool {
        if case .submenu = action { return true }
        return false
    }
}

enum DialOutcome {
    case stay
    case nowPlaying
    case message(String)
    case refresh
    case exit
}

/// A menu level; a class so its selection survives pushes and pops. Items
/// come from a builder so rows showing a setting's value can be reloaded.
final class DialMenu: Identifiable {
    let id = UUID()
    let title: String
    private let build: () -> [DialItem]
    private(set) var items: [DialItem]
    var selection: Int

    init(title: String, selection: Int = 0, build: @escaping () -> [DialItem]) {
        self.title = title
        self.build = build
        let built = build()
        self.items = built
        self.selection = max(0, min(selection, max(built.count - 1, 0)))
    }

    convenience init(title: String, items: [DialItem], selection: Int = 0) {
        self.init(title: title, selection: selection, build: { items })
    }

    func reload() {
        items = build()
        selection = max(0, min(selection, max(items.count - 1, 0)))
    }
}

/// The dial-mode state machine: a stack of screens driven by four inputs —
/// rotate (± detents), select (centre button), back, and play/pause.
@MainActor
final class DialNavigator: ObservableObject {

    enum Screen {
        case menu(DialMenu)
        case nowPlaying
        case message(String)
    }

    @Published private(set) var stack: [Screen]
    @Published var exitRequested = false
    /// Last seek direction on Now Playing, for the on-screen hint.
    @Published private(set) var lastSeek: (delta: Int, at: Date)?

    weak var player: PlayerManager?
    var rootBuilder: () -> DialMenu
    static let seekStep: TimeInterval = 5

    init(root: @escaping () -> DialMenu) {
        rootBuilder = root
        stack = [.menu(root())]
    }

    var top: Screen { stack.last ?? .menu(rootBuilder()) }

    /// Back to a freshly built root menu.
    func resetToRoot() {
        stack = [.menu(rootBuilder())]
    }
    var depth: Int { stack.count }

    // MARK: - Inputs

    /// Moves `delta` detents. Returns false when the move hit the end of a
    /// list (so the caller can play the end-stop haptic instead of a tick).
    @discardableResult
    func rotate(_ delta: Int) -> Bool {
        guard delta != 0 else { return true }
        switch top {
        case .menu(let menu):
            guard !menu.items.isEmpty else { return false }
            let next = max(0, min(menu.items.count - 1, menu.selection + delta))
            guard next != menu.selection else { return false }
            menu.selection = next
            objectWillChange.send()
            return true
        case .nowPlaying:
            guard let player, player.currentTrack != nil else { return false }
            let duration = player.duration
            var target = player.currentTime + Self.seekStep * Double(delta)
            if duration > 0 { target = min(max(0, target), max(0, duration - 1)) } else { target = max(0, target) }
            player.seek(to: target)
            lastSeek = (delta, Date())
            return true
        case .message:
            pop()
            return true
        }
    }

    func select() {
        switch top {
        case .menu(let menu):
            guard menu.items.indices.contains(menu.selection) else { return }
            run(menu.items[menu.selection].action)
        case .nowPlaying:
            player?.togglePlayPause()
        case .message:
            pop()
        }
    }

    /// Returns false at the root (nothing to go back to).
    @discardableResult
    func back() -> Bool {
        guard stack.count > 1 else { return false }
        pop()
        return true
    }

    func playPause() { player?.togglePlayPause() }
    func next() { player?.nextTrack() }
    func previous() { player?.previousTrack() }

    func showNowPlaying() {
        if case .nowPlaying = top { return }
        stack.append(.nowPlaying)
    }

    func showMessage(_ text: String) {
        stack.append(.message(text))
    }

    /// Reloads every menu's rows (e.g. the root after playback started).
    func reloadMenus() {
        for screen in stack {
            if case .menu(let m) = screen { m.reload() }
        }
        objectWillChange.send()
    }

    // MARK: - Internals

    private func run(_ action: DialItem.Action) {
        switch action {
        case .submenu(let build):
            stack.append(.menu(build()))
        case .play(let tracks, let index):
            guard !tracks.isEmpty else {
                showMessage("Nothing to play")
                return
            }
            player?.playSlice(tracks, startIndex: index)
            showNowPlaying()
        case .nowPlaying:
            if player?.currentTrack == nil {
                showMessage("Nothing playing")
            } else {
                showNowPlaying()
            }
        case .perform(let work):
            switch work() {
            case .stay: break
            case .nowPlaying: showNowPlaying()
            case .message(let text): showMessage(text)
            case .refresh:
                refreshCurrentMenu()
            case .exit: exitRequested = true
            }
        }
    }

    /// Settings rows show their current value; reload after a change.
    private func refreshCurrentMenu() {
        if case .menu(let m) = top { m.reload() }
        objectWillChange.send()
    }

    private func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }
}
