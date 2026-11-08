import SwiftUI

struct ContentView: View {
    @StateObject private var store = AppStore.shared
    @StateObject private var api = API.shared

    var body: some View {
        ZStack {
            switch store.tab {
            case .home: HomeView()
            case .search: SearchView()
            case .category: CategoryView()
            case .profile: ProfileView()
            }
        }
        .sheet(isPresented: $store.loginOpen) {
            LoginView()
        }
        .tabBar(isHidden: store.tab == .home) {
            HStack {
                TabItem(icon: "house", label: "首页", tab: .home)
                TabItem(icon: "magnifyingglass", label: "搜索", tab: .search)
                TabItem(icon: "grid", label: "分类", tab: .category)
                TabItem(icon: "person", label: "我的", tab: .profile)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(.systemBackground).opacity(0.96))
        }
    }
}

struct TabItem: View {
    var icon: String
    var label: String
    var tab: AppStore.Tab
    @StateObject private var store = AppStore.shared
    var body: some View {
        Button {
            store.tab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: store.tab == tab ? "\(icon).fill" : icon)
                Text(label).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(store.tab == tab ? .primary : .secondary)
        }
    }
}

extension View {
    func tabBar(isHidden: Bool, content: Content) -> some View {
        ZStack(alignment: .bottom) {
            self
            if !isHidden { content }
        }
    }
}

// MARK: - Home feed (immersive vertical reels, mirrors Feed.tsx + Home.tsx)

struct HomeView: View {
    @StateObject private var api = API.shared
    @StateObject private var store = AppStore.shared
    @State private var items: [VideoCard] = []
    @State private var page = 1
    @State private var loading = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        ZStack {
            if items.isEmpty {
                if loading { ProgressView() }
                else { emptyState }
            } else {
                FeedPager(items: items, onNearEnd: { Task { await load(page + 1) } })
            }
        }
        .task { await load(1) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                Button { store.setMuted(!store.muted) } label: {
                    Image(systemName: store.muted ? "speaker.slash" : "speaker.wave.2")
                }
                Button { store.tab = .search } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(Color.black.opacity(0.4), in: Circle())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if let e = error {
                Text(e).foregroundStyle(.secondary)
                Button("重试") { Task { await load(1) } }
            } else {
                ProgressView()
            }
        }
    }

    func load(_ p: Int) async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await api.feed(page: p, size: 10)
            let seen = Set(items.map(\.id))
            items += res.items.filter { !seen.contains($0.id) }
            page = p
            if res.items.isEmpty || p >= res.pagination.pages { done = true }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Vertical pager with AVPlayer (mirrors Feed.tsx)

struct FeedPager: View {
    var items: [VideoCard]
    var onNearEnd: () -> Void
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items.indices, id: \.self) { idx in
                FeedPage(card: items[idx], index: idx, total: items.count)
                    .tag(idx)
                    .onChange(of: selection) {
                        if idx >= items.count - 2 { onNearEnd() }
                    }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #if !os(tvOS)
        .tabViewStyle(.page)
        #endif
    }
}

struct FeedPage: View {
    var card: VideoCard
    var index: Int
    var total: Int
    @StateObject private var api = API.shared
    @StateObject private var store = AppStore.shared
    @State private var detail: Detail?
    @State private var playInfo: PlayInfo?
    @State private var showComments = false
    @State private var showEpisodes = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CoverPlayerView(card: card, ep: currentEp, detail: $detail, playInfo: $playInfo)
            // Info overlay
            VStack(alignment: .leading, spacing: 8) {
                if let d = detail {
                    Text(d.title).font(.headline).foregroundStyle(.white)
                    if d.is_finished { Text("已完结").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                } else {
                    Text(card.title).font(.headline).foregroundStyle(.white)
                }
                Text("集数 \(card.episode_count) · 评分 \(card.score, specifier: "%.1f")")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.bottom, 90)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            )
            // Action rail
            VStack(spacing: 18) {
                Button { Task { await toggleLike() } } label: {
                    VStack(spacing: 2) {
                        Image(systemName: store.isLiked(card.id) ? "heart.fill" : "heart")
                        Text(fmt(card.like_count)).font(.caption)
                    }
                }
                Button { Task { await toggleCollect() } } label: {
                    VStack(spacing: 2) {
                        Image(systemName: store.isFav(card.id) ? "star.fill" : "star")
                        Text(fmt(card.collect_count)).font(.caption)
                    }
                }
                Button { showComments = true } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "message")
                        Text(fmt(card.comment_count)).font(.caption)
                    }
                }
                Button { showEpisodes = true } label: {
                    Image(systemName: "list.bullet")
                }
            }
            .foregroundStyle(.white)
            .padding(.trailing, 12)
            .padding(.bottom, 100)
        }
        .task {
            detail = try? await api.video(id: card.id)
        }
        .sheet(isPresented: $showComments) {
            CommentsView(videoId: card.id, ep: currentEp)
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodesView(detail: detail)
        }
    }

    private var currentEp: Int { 1 }

    func toggleLike() async {
        let on = store.toggleLikeLocal(card.id)
        if api.loggedIn { try? await api.like(id: card.id, ep: currentEp, on: on) }
    }
    func toggleCollect() async {
        let on = store.toggleFavLocal(card.id)
        if api.loggedIn { try? await api.collect(id: card.id, on: on) }
    }
}

// Cover + AVPlayer with poster, tap-to-pause, progress polling for history.
struct CoverPlayerView: UIViewRepresentable {
    var card: VideoCard
    var ep: Int
    @Binding var detail: Detail?
    @Binding var playInfo: PlayInfo?
    @State private var player: AVPlayer?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        container.layer.addSublayer(layer)
        context.coordinator.playerLayer = layer
        context.coordinator.container = container
        // Tap to pause/play
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggle))
        container.addGestureRecognizer(tap)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Load cover as poster placeholder
        Task {
            if let img = try? await CoverLoader.shared.loadUIImage(url: card.cover) {
                context.coordinator.posterView?.image = img
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(detail: detail, playInfo: playInfo)
    }

    final class Coordinator: NSObject {
        var playerLayer: AVPlayerLayer?
        var container: UIView?
        var posterView: UIImageView?
        var player: AVPlayer?
        var detail: Detail?
        var playInfo: PlayInfo?
        var historyTimer: Timer?

        init(detail: Detail?, playInfo: PlayInfo?) {
            self.detail = detail
            self.playInfo = playInfo
        }

        @objc func toggle() {
            if player?.rate != 0 { player?.pause() } else { player?.play() }
        }

        func play(url: String) {
            guard let u = URL(string: url) else { return }
            player = AVPlayer(url: u)
            player?.volume = AppStore.shared.muted ? 0 : Float(AppStore.shared.volume)
            playerLayer?.player = player
            player?.play()
            startHistoryTimer()
        }

        private func startHistoryTimer() {
            historyTimer?.invalidate()
            historyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let p = self?.player else { return }
                let t = p.currentTime().seconds
                let dur = p.currentItem()?.duration.seconds ?? 0
                if t.isFinite {
                    Task { @MainActor in
                        AppStore.shared.addHistory(self?.detail?.id ?? 0, ep: 1, t: t, dur: dur.isFinite ? dur : 0)
                    }
                }
            }
        }
    }
}

struct CommentsView: View {
    var videoId: Int
    var ep: Int
    @StateObject private var api = API.shared
    @State private var comments: [Comment] = []
    @State private var text = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List(comments) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(c.nickname).font(.caption).bold()
                        Text(c.time).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(c.text).font(.body)
                }
            }
            .navigationTitle("评论")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        TextField("说点什么", text: $text)
                            .textFieldStyle(.roundedBorder)
                        Button("发送") { Task { await send() } }
                    }
                }
            }
            .task { await load() }
        }
    }

    func load() async {
        loading = true
        if let page = try? await api.comments(id: videoId, ep: ep, page: 1, size: 20) {
            comments = page.items
        }
        loading = false
    }
    func send() async {
        guard !text.isEmpty else { return }
        do { try await api.commentSend(id: videoId, ep: ep, text: text); text = ""; await load() }
        catch { }
    }
}

struct EpisodesView: View {
    var detail: Detail?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(detail?.episodes ?? []) { ep in
                Button("\(ep.title) · \(fmtTime(ep.duration))") { dismiss() }
            }
            .navigationTitle(detail?.title ?? "选集")
        }
    }
}
