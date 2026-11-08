import Foundation

// MARK: - Persisted local state (mirrors store.tsx hghub_app_v1)

public struct WatchProgress: Codable, Equatable {
    public var id: Int
    public var ep: Int
    public var t: Double
    public var dur: Double
    public var at: Int64 // ms
}

struct PersistState: Codable {
    var likes: [Int] = []
    var favs: [Int] = []
    var history: [WatchProgress] = []
    var follows: [Int] = []
    var muted: Bool = true
    var volume: Double = 0.7
    var searchHist: [String] = []
}

@MainActor
public final class AppStore: ObservableObject {
    public static let shared = AppStore()

    private static let lsKey = "hghub_app_v1"
    private static let themeKey = "hghub_theme"

    @Published public var likes: [Int] = []
    @Published public var favs: [Int] = []
    @Published public var history: [WatchProgress] = []
    @Published public var follows: [Int] = []
    @Published public var muted: Bool = true
    @Published public var volume: Double = 0.7
    @Published public var searchHist: [String] = []

    public enum Theme: String, Codable { case dark, light }
    @Published public var theme: Theme = .dark {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    public enum Tab: String { case home, search, category, profile }
    @Published public var tab: Tab = .home

    @Published public var loginOpen: Bool = false

    public init() {
        if let raw = UserDefaults.standard.string(forKey: Self.themeKey) {
            theme = Theme(rawValue: raw) ?? .dark
        }
        loadPersist()
    }

    // --- persistence ---

    private func loadPersist() {
        guard let data = UserDefaults.standard.data(forKey: Self.lsKey),
              let p = try? JSONDecoder().decode(PersistState.self, from: data) else { return }
        likes = p.likes; favs = p.favs; history = normalizeHistory(p.history)
        follows = p.follows; muted = p.muted; volume = p.volume; searchHist = p.searchHist
    }

    private func savePersist() {
        let p = PersistState(likes: likes, favs: favs, history: history, follows: follows,
                             muted: muted, volume: volume, searchHist: searchHist)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.lsKey)
        }
    }

    private func normalizeHistory(_ raw: [WatchProgress]) -> [WatchProgress] {
        raw.filter { $0.id != 0 }
    }

    // --- local toggles ---

    public func isLiked(_ id: Int) -> Bool { likes.contains(id) }
    public func isFav(_ id: Int) -> Bool { favs.contains(id) }

    @discardableResult
    public func toggleLikeLocal(_ id: Int) -> Bool {
        let on = !likes.contains(id)
        likes = on ? [id] + likes : likes.filter { $0 != id }
        savePersist()
        return on
    }
    @discardableResult
    public func toggleFavLocal(_ id: Int) -> Bool {
        let on = !favs.contains(id)
        favs = on ? [id] + favs : favs.filter { $0 != id }
        savePersist()
        return on
    }
    @discardableResult
    public func toggleFollowLocal(_ uid: Int) -> Bool {
        let on = !follows.contains(uid)
        follows = on ? [uid] + follows : follows.filter { $0 != uid }
        savePersist()
        return on
    }

    public func addHistory(_ id: Int, ep: Int? = nil, t: Double? = nil, dur: Double? = nil) {
        guard id != 0 else { return }
        let prev = history.first { $0.id == id }
        let epChanged = ep != nil && prev != nil && prev!.ep != ep!
        let entry = WatchProgress(
            id: id,
            ep: ep ?? prev?.ep ?? 1,
            t: epChanged ? 0 : (t ?? prev?.t ?? 0),
            dur: dur ?? prev?.dur ?? 0,
            at: Int64(Date().timeIntervalSince1970 * 1000))
        history = [entry] + history.filter { $0.id != id }
        history = Array(history.prefix(80))
        savePersist()
    }

    public func clearHistory() {
        history = []
        savePersist()
    }

    public func addSearch(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        searchHist = [t] + searchHist.filter { $0 != t }
        searchHist = Array(searchHist.prefix(12))
        savePersist()
    }
    public func clearSearchHist() {
        searchHist = []
        savePersist()
    }

    public func setMuted(_ v: Bool) { muted = v; savePersist() }
    public func setVolume(_ v: Double) {
        volume = min(1, max(0, v))
        muted = (volume == 0)
        savePersist()
    }
}
