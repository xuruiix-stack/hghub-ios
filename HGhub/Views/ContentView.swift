import AVFoundation
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
        // Original App.tsx always renders the bottom TabBar; hiding it on
        // home made the home feed have no tab bar at all.
        .tabBar(isHidden: false) {
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
    func tabBar<Content: View>(isHidden: Bool, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .bottom) {
            self
            if !isHidden { content() }
        }
    }
}

// MARK: - Home feed (mirrors Feed.tsx + Home.tsx)

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
    @State private var epMap: [Int: Int] = [:]
    @State private var showComments = false
    @State private var showEpisodes = false
    @State private var sheetDetail: Detail?
    @State private var sheetCard: VideoCard?
    @State private var sheetEp: Int = 1

    private var currentCard: VideoCard? {
        items.indices.contains(selection) ? items[selection] : items.first
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items.indices, id: \.self) { idx in
                FeedPage(
                    card: items[idx],
                    index: idx,
                    total: items.count,
                    isActive: idx == selection,
                    epMap: $epMap,
                    requestEpisodes: { detail, card, ep in
                        sheetDetail = detail
                        sheetCard = card
                        sheetEp = ep
                        showEpisodes = true
                    },
                    requestComments: { _ in showComments = true }
                )
                .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onChange(of: selection) { _ in
            if selection >= items.count - 2 { onNearEnd() }
        }
        .sheet(isPresented: $showEpisodes) {
            EpisodesView(
                detail: sheetDetail,
                fallbackCount: sheetCard?.episode_count ?? 0,
                current: sheetEp,
                onPick: { ep in
                    if let id = sheetCard?.id { epMap[id] = ep }
                    showEpisodes = false
                }
            )
        }
        .sheet(isPresented: $showComments) {
            if let card = currentCard {
                CommentsView(videoId: card.id, ep: epMap[card.id] ?? 1)
            } else {
                Text("暂无内容")
            }
        }
    }
}

struct FeedPage: View {
    var card: VideoCard
    var index: Int
    var total: Int
    var isActive: Bool
    @Binding var epMap: [Int: Int]
    var requestEpisodes: (Detail?, VideoCard, Int) -> Void
    var requestComments: (Int) -> Void

    @StateObject private var api = API.shared
    @StateObject private var store = AppStore.shared
    @State private var detail: Detail?
    @State private var playURL: String?
    @State private var playLoading = true
    @State private var playError: String?
    @State private var isPlaying = false
    @State private var loadedKey = ""
    // v1.2.0 player features (see PlayerFeatures.swift)
    @StateObject private var gesture = PlayerGestureModel()
    @State private var fullscreen = false
    @State private var systemLandscape = false

    private var currentEp: Int { epMap[card.id] ?? 1 }

    /// Next episode by ep_num (mirrors Feed.tsx onEnded → pickEp).
    private var nextEpisode: Episode? {
        detail?.episodes.first { $0.ep_num == currentEp + 1 }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CoverPlayerView(
                card: card,
                active: isActive,
                urlString: playURL,
                muted: store.muted,
                volume: store.volume,
                gestureModel: isActive ? gesture : nil,
                isPlaying: $isPlaying,
                errorMsg: $playError,
                onProgress: { t, dur in
                    store.addHistory(card.id, ep: currentEp, t: t, dur: dur)
                },
                onNearEnd: { autoAdvanceIfPossible() },
                onEnded: { autoAdvanceIfPossible() }
            )
            if playLoading, playURL == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            if playURL != nil, playError == nil, !playLoading, !isPlaying,
               gesture.cleanMode == false {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 66, height: 66)
                    Image(systemName: "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            if let playError {
                VStack(spacing: 10) {
                    Text("视频暂时无法加载").foregroundStyle(.white)
                    Text(playError)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                    Button("重试") {
                        self.playError = nil
                        playURL = nil
                        Task { await loadPlayInfo() }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                }
                .padding(16)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // cleanMode hides every chrome overlay (single tap toggles).
            Group {
                VStack(alignment: .leading, spacing: 8) {
                    if let d = detail {
                        Text(d.title).font(.headline).foregroundStyle(.white)
                        if d.is_finished { Text("已完结").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                    } else {
                        Text(card.title).font(.headline).foregroundStyle(.white)
                    }
                    Text("集数 \(card.episode_count) · 评分 \(card.score, specifier: "%.1f")")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                    // v1.2.0: draggable progress bar (portrait, above tab bar).
                    PlayerProgressBar(model: gesture)
                        .frame(height: 26)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.bottom, 90)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                )
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
                    Button { requestComments(card.id) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "message")
                            Text(fmt(card.comment_count)).font(.caption)
                        }
                    }
                    Button { requestEpisodes(detail, card, currentEp) } label: {
                        Image(systemName: "list.bullet")
                    }
                    // v1.2.0: playback lock + fullscreen entry.
                    Button { gesture.controlsLocked = true } label: {
                        Image(systemName: "lock")
                    }
                    .accessibilityLabel("锁定播放控制")
                    Button { enterFullscreen() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("横屏全屏")
                }
                .foregroundStyle(.white)
                .padding(.trailing, 12)
                .padding(.bottom, 100)
            }
            .opacity(gesture.cleanMode ? 0 : 1)
        }
        .overlay {
            if gesture.controlsLocked {
                PlaybackLockOverlay { gesture.controlsLocked = false }
            }
        }
        .overlay {
            if fullscreen {
                FullscreenPlayerOverlay(model: gesture) { exitFullscreen() }
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .task {
            detail = try? await api.video(id: card.id)
            await loadPlayInfo()
        }
        .onChange(of: currentEp) { _ in
            playURL = nil
            playError = nil
            gesture.resetForNewMedia()
            Task { await loadPlayInfo() }
        }
        .onChange(of: systemLandscape) { landscape in
            // Physical rotation drives fullscreen both ways (mirrors
            // Feed.tsx viewport-change listener).
            guard isActive else { return }
            if landscape { enterFullscreen() } else if fullscreen { exitFullscreen() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIDevice.orientationDidChangeNotification)) { _ in
            // Track the *interface* orientation: when the system honors our
            // requestGeometryUpdate the device notification also fires, and
            // interface orientation is the truth used by Feed.tsx's
            // innerWidth > innerHeight check.
            let landscape = OrientationController.isDeviceLandscape
            if landscape != systemLandscape {
                systemLandscape = landscape
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
    }

    // MARK: v1.2.0 fullscreen entry points

    private func enterFullscreen() {
        fullscreen = true
        gesture.cleanMode = false
        OrientationController.requestLandscape(true)
    }

    private func exitFullscreen() {
        fullscreen = false
        OrientationController.requestLandscape(false)
    }

    /// Auto-advance to the next episode (mirrors Feed.tsx onEnded handler).
    /// Near-end fires ~0.35s early because some HLS containers report a
    /// duration slightly longer than the last segment (see VideoSurface.tsx).
    private func autoAdvanceIfPossible() {
        guard isActive, playError == nil else { return }
        guard let next = nextEpisode else { return }
        epMap[card.id] = next.ep_num
        // onChange(of: currentEp) reloads play info.
    }

    func loadPlayInfo() async {
        let key = "\(card.id):\(currentEp)"
        guard loadedKey != key || playURL == nil else { return }
        loadedKey = key
        playLoading = true
        playError = nil
        defer { playLoading = false }
        do {
            let info = try await api.play(id: card.id, ep: currentEp)
            guard !info.video_url.isEmpty else { throw APIError.network("暂无播放地址") }
            let upstreamHost = hostOf(info.video_url)
            await HLSProxy.shared.waitUntilReady()
            guard HLSProxy.shared.isReady else {
                throw PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                    httpStatus: nil, code: nil, domain: nil,
                    message: "本地代理未就绪，请重试（上游 \(upstreamHost)）")
            }
            let proxyURL = HGAUrl.playlist(info.video_url, proxy: HLSProxy.shared)
            // Prove the loopback proxy serves before AVPlayer ever sees
            // the URL, so a dead proxy is reported as such (not as a CDN
            // unreachable failure on the user's network).
            // One automatic retry of the whole load (~1s later) before
            // surfacing the error, so a transient loopback flap does not
            // fail the video. The manual retry button stays as-is.
            do {
                try await HLSProxy.shared.selfCheck(playlistProxyURL: proxyURL)
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    try await HLSProxy.shared.selfCheck(playlistProxyURL: proxyURL)
                } catch {
                    if let d = error as? PlaybackDiagnostic {
                        playError = "loopback 代理不可用：\(d.diagnosticString())（上游 \(upstreamHost)）"
                    } else {
                        playError = "loopback 代理不可用：\(error.localizedDescription)（上游 \(upstreamHost)）"
                    }
                    return
                }
            }
            playURL = proxyURL
            store.addHistory(card.id, ep: currentEp)
        } catch {
            // api.play failure: preserve structured diagnostics when present,
            // otherwise surface the API error verbatim (it names the step).
            if let d = error as? PlaybackDiagnostic {
                playError = d.diagnosticString()
            } else {
                playError = error.localizedDescription
            }
        }
    }

    func toggleLike() async {
        let on = store.toggleLikeLocal(card.id)
        if api.loggedIn { try? await api.like(id: card.id, ep: currentEp, on: on) }
    }
    func toggleCollect() async {
        let on = store.toggleFavLocal(card.id)
        if api.loggedIn { try? await api.collect(id: card.id, on: on) }
    }
}

// MARK: - UIKit-backed player (poster + AVPlayerLayer with real layout)

final class PlayerContainerView: UIView {
    private var posterView: UIImageView!
    private var spinner: UIActivityIndicatorView!
    private var label: UILabel!

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspectFill
        posterView = UIImageView()
        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        posterView.isUserInteractionEnabled = false
        addSubview(posterView)
        spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.isUserInteractionEnabled = false
        spinner.startAnimating()
        addSubview(spinner)
        label = UILabel()
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 2
        label.textAlignment = .center
        label.isHidden = true
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
        posterView.frame = bounds
        spinner.center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        label.frame = CGRect(x: 16, y: bounds.height - 84, width: bounds.width - 32, height: 44)
    }

    func setPoster(_ image: UIImage?) { posterView.image = image }
    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
    func setMessage(_ text: String?) {
        label.text = text
        label.isHidden = text == nil
    }
    func hidePoster() { posterView.isHidden = true }
    func showPoster() { posterView.isHidden = false }
}

struct CoverPlayerView: UIViewRepresentable {
    var card: VideoCard
    var active: Bool
    var urlString: String?
    var muted: Bool
    var volume: Double
    /// v1.2.0 gesture bridge; nil disables gestures (inactive pages).
    var gestureModel: PlayerGestureModel?
    @Binding var isPlaying: Bool
    @Binding var errorMsg: String?
    var onProgress: (Double, Double) -> Void
    /// Fires ~0.35s before the true end (HLS duration overhang) so the
    /// next-episode switch happens without a stalled last frame.
    var onNearEnd: (() -> Void)?
    /// Fires on AVPlayerItem.didPlayToEndTime.
    var onEnded: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let container = PlayerContainerView(frame: .zero)
        // v1.2.0: single tap toggles play only when no gesture model is
        // attached (gesture model owns tap/double-tap semantics instead).
        if gestureModel == nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggle))
            container.addGestureRecognizer(tap)
        }
        return container
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        let c = context.coordinator
        c.onPlayingChange = { playing in isPlaying = playing }
        c.onError = { msg in errorMsg = msg }
        c.bindGestureModel(gestureModel, container: uiView)
        c.onNearEnd = onNearEnd
        c.onEnded = onEnded
        c.sync(container: uiView, card: card, url: urlString, active: active,
               muted: muted, volume: volume, onProgress: onProgress)
    }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject {
        private var container: PlayerContainerView?
        private var player: AVPlayer?
        private var currentURL: String?
        private var active = false
        private var userPaused = false
        private var posterCover: String?
        private var posterTask: Task<Void, Never>?
        private var watchdogTimer: Timer?
        private var timeControlObs: NSKeyValueObservation?
        private var currentItemObs: NSKeyValueObservation?
        private var itemStatusObs: NSKeyValueObservation?
        private var failedObs: NSObjectProtocol?
        private var endedObs: NSObjectProtocol?
        private var historyTimer: Timer?
        private var nearEndFired = false
        // v1.2.0 gesture bridge (weak: SwiftUI owns the model).
        private weak var gestureModel: PlayerGestureModel?
        private var gesturesAttached = false

        var onPlayingChange: ((Bool) -> Void)?
        var onError: ((String?) -> Void)?
        var onProgress: ((Double, Double) -> Void)?
        var onNearEnd: (() -> Void)?
        var onEnded: (() -> Void)?

        /// Wire the SwiftUI gesture model to this player: expose the
        /// AVPlayerLayer for the fullscreen stage, install UIKit
        /// recognizers once, and route model commands back here.
        func bindGestureModel(_ model: PlayerGestureModel?, container: PlayerContainerView) {
            if let model {
                gestureModel = model
                model.playerLayer = container.videoLayer
                if !gesturesAttached {
                    model.attach(to: container)
                    gesturesAttached = true
                }
                model.onTogglePlay = { [weak self] in
                    // Keep user-pause semantics identical to the old tap.
                    self?.toggle()
                }
                model.onSeek = { [weak self] t, _ in
                    self?.seek(to: t)
                }
                model.onRateChange = { [weak self] rate in
                    self?.applyRate(rate)
                }
            } else {
                gestureModel = nil
            }
        }

        func sync(container: PlayerContainerView, card: VideoCard, url: String?,
                  active: Bool, muted: Bool, volume: Double,
                  onProgress: @escaping (Double, Double) -> Void) {
            self.container = container
            self.onProgress = onProgress
            applyVolume(muted: muted, volume: volume)
            loadPosterIfNeeded(card: card)
            if url != currentURL {
                currentURL = url
                nearEndFired = false
                rebuildPlayer(url: url)
                // New media: reset transient gesture state so a stale scrub
                // target or zoom transform does not leak into the next item.
                gestureModel?.resetForNewMedia()
            }
            let becameActive = active && !self.active
            let becameInactive = !active && self.active
            self.active = active
            if becameInactive {
                userPaused = false
                pauseInternal()
            }
            if becameActive, player != nil, !userPaused {
                playInternal()
            }
        }

        func teardown() {
            historyTimer?.invalidate()
            historyTimer = nil
            uiTickTimer?.invalidate()
            uiTickTimer = nil
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            removeObservers()
            player?.pause()
            player = nil
            container?.videoLayer.player = nil
            container = nil
            posterTask?.cancel()
            posterTask = nil
            gestureModel = nil
        }

        @objc func toggle() {
            guard let p = player else { return }
            if p.rate != 0 {
                userPaused = true
                p.pause()
            } else {
                userPaused = false
                p.play()
            }
        }

        /// v1.2.0: precise seek used by the progress bar and the
        /// horizontal-drag gesture. Clamps into the item duration.
        func seek(to t: Double) {
            guard let p = player, let item = p.currentItem else { return }
            let dur = item.duration.seconds
            let target = dur.isFinite && dur > 0 ? min(max(0, t), dur - 0.15) : max(0, t)
            p.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }

        /// v1.2.0: base/hold/locked playback rate (2x long-press etc.).
        /// Setting AVPlayer.rate while paused keeps the item paused, so use
        /// playImmediately(atRate:) for the resume path.
        func applyRate(_ rate: Float) {
            guard let p = player else { return }
            if rate <= 0 {
                p.pause()
                return
            }
            if userPaused { userPaused = false }
            if p.rate == 0 {
                p.playImmediately(atRate: rate)
            } else if p.rate != rate {
                p.rate = rate
            }
        }

        private func rebuildPlayer(url: String?) {
            removeObservers()
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            uiTickTimer?.invalidate()
            uiTickTimer = nil
            player?.pause()
            player = nil
            container?.videoLayer.player = nil
            container?.showPoster()
            guard let url, let u = URL(string: url) else {
                container?.setLoading(false)
                currentURL = nil
                return
            }
            let p = AVPlayer(url: u)
            player = p
            container?.videoLayer.player = p
            container?.setLoading(true)
            container?.setMessage("加载中…")
            observe(p)
            if active, !userPaused {
                playInternal()
            } else {
                p.pause()
            }
            startHistoryTimer()
            startUITick()
            startWatchdog()
        }

        /// Stall watchdog: AVPlayer can sit in `.unknown` / waiting forever
        /// without ever reaching `.readyToPlay` or `.failed` (e.g. an
        /// unparseable playlist). Fires once, 15s after the player starts,
        /// and only if playback is expected (active + user has not paused)
        /// but still has not progressed. Surfaces through onError →
        /// FeedPage's "视频暂时无法加载" + retry UI.
        private static let stallWatchSeconds: TimeInterval = 15

        private func startWatchdog() {
            watchdogTimer?.invalidate()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.stallWatchSeconds, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.checkStall() }
            }
        }

        private func checkStall() {
            watchdogTimer = nil
            guard let p = player, active, !userPaused else { return }
            let item = p.currentItem
            let itemReady = item?.status == .readyToPlay
            let hasProgressed = p.rate != 0 && p.timeControlStatus == .playing
                || (p.currentTime().seconds.isFinite && p.currentTime().seconds > 0)
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate && p.rate != 0
            let stall = (!itemReady && !hasProgressed) || (waiting && !hasProgressed)
            guard stall else { return }
            let urlStr = currentURL ?? ""
            let host = upstreamHostOf(urlStr) ?? hostOf(urlStr)
            let last = HLSProxy.shared.lastDiagnostic ?? ""
            let msg = "视频加载超时（15 秒），请检查网络后重试"
                + " host=\(host.isEmpty ? "127.0.0.1" : host)"
                + (last.isEmpty ? "" : " proxy:\(last)")
            handleFailure(msg)
        }

        private func playInternal() {
            player?.play()
        }

        private func pauseInternal() {
            player?.pause()
            onPlayingChange?(false)
        }

        private func applyVolume(muted: Bool, volume: Double) {
            let desired: Float = muted ? 0 : Float(volume)
            if let p = player, p.volume != desired { p.volume = desired }
        }

        private func observe(_ p: AVPlayer) {
            timeControlObs = p.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { self?.syncPlayingState() }
            }
            currentItemObs = p.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                DispatchQueue.main.async { self?.observeCurrentItem(player.currentItem) }
            }
            observeCurrentItem(p.currentItem)
            failedObs = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let self else { return }
                let item = note.object as? AVPlayerItem
                let err = item?.error
                self.handleFailure(self.diagnosticForItemError(err))
            }
            // v1.2.0: natural end → next episode (see onEnded / onNearEnd).
            endedObs = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if !self.nearEndFired {
                    self.nearEndFired = true
                    self.onEnded?()
                }
            }
        }

        private func observeCurrentItem(_ item: AVPlayerItem?) {
            itemStatusObs?.invalidate()
            itemStatusObs = nil
            guard let item else { return }
            itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async { self?.handleItemStatus(item) }
            }
        }

        private func removeObservers() {
            timeControlObs?.invalidate()
            timeControlObs = nil
            currentItemObs?.invalidate()
            currentItemObs = nil
            itemStatusObs?.invalidate()
            itemStatusObs = nil
            if let failedObs {
                NotificationCenter.default.removeObserver(failedObs)
                self.failedObs = nil
            }
            if let endedObs {
                NotificationCenter.default.removeObserver(endedObs)
                self.endedObs = nil
            }
        }

        private func handleItemStatus(_ item: AVPlayerItem) {
            switch item.status {
            case .readyToPlay:
                // The item is good; the watchdog has served its purpose.
                watchdogTimer?.invalidate()
                watchdogTimer = nil
                container?.setLoading(false)
                container?.setMessage(nil)
            case .failed:
                handleFailure(diagnosticForItemError(item.error))
            case .unknown:
                break
            @unknown default:
                break
            }
        }

        private func syncPlayingState() {
            guard let p = player else { return }
            let playing = p.timeControlStatus == .playing
            if playing {
                container?.hidePoster()
                container?.setLoading(false)
                container?.setMessage(nil)
            } else if p.timeControlStatus == .waitingToPlayAtSpecifiedRate, p.rate != 0 {
                container?.setLoading(true)
            } else {
                container?.setLoading(false)
            }
            gestureModel?.isPlaying = playing
            onPlayingChange?(playing)
        }

        private func handleFailure(_ message: String) {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            player?.pause()
            container?.setLoading(false)
            container?.setMessage(nil)
            onPlayingChange?(false)
            onError?(message)
        }

        /// Structured AVPlayer item failure: NSError code + domain, which
        /// step (item vs segment/key), the upstream host recovered from the
        /// proxy URL, and the proxy's last recorded diagnostic. This is
        /// what distinguishes "loopback proxy dead" from "CDN unreachable
        /// from the user's network".
        private func diagnosticForItemError(_ error: Error?) -> String {
            let urlStr = currentURL ?? ""
            let host = upstreamHostOf(urlStr) ?? hostOf(urlStr)
            let last = HLSProxy.shared.lastDiagnostic ?? ""
            guard let err = error as NSError? else {
                return "播放失败 host=\(host.isEmpty ? "127.0.0.1" : host)" + (last.isEmpty ? "" : " proxy:\(last)")
            }
            let http = httpStatusFromMessage(err.localizedDescription)
            let diag = PlaybackDiagnostic(step: "item", host: host.isEmpty ? "127.0.0.1" : host,
                httpStatus: http, code: err.code, domain: err.domain,
                message: err.localizedDescription)
            return diag.diagnosticString() + (last.isEmpty ? "" : " proxy:\(last)")
        }

        private func loadPosterIfNeeded(card: VideoCard) {
            guard posterCover != card.cover else { return }
            posterCover = card.cover
            container?.showPoster()
            posterTask?.cancel()
            guard !card.cover.isEmpty else { return }
            let cover = card.cover
            posterTask = Task {
                guard let img = try? await CoverLoader.shared.loadUIImage(url: cover) else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.posterCover == cover else { return }
                    self.container?.setPoster(img)
                }
            }
        }

        private func startHistoryTimer() {
            historyTimer?.invalidate()
            historyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let p = self?.player else { return }
                let t = p.currentTime().seconds
                let dur = p.currentItem?.duration.seconds ?? 0
                if t.isFinite {
                    self?.onProgress?(t, dur.isFinite ? dur : 0)
                }
            }
        }

        /// v1.2.0: 10Hz UI tick. Feeds the gesture model (progress bar,
        /// scrub base) and fires the near-end hook 0.35s early — some HLS
        /// containers report a duration slightly longer than the last
        /// segment, so waiting for didPlayToEndTime stalls on the final
        /// frame (mirrors VideoSurface.tsx nearEndFiredRef).
        private var uiTickTimer: Timer?
        private func startUITick() {
            uiTickTimer?.invalidate()
            uiTickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard let p = self.player else { return }
                let t = p.currentTime().seconds
                let dur = p.currentItem?.duration.seconds ?? 0
                guard t.isFinite else { return }
                // Publish to the gesture model on main (Timer is main-only).
                if let m = self.gestureModel {
                    if !m.barScrubbing, self.gestureModel?.scrub == nil { m.currentTime = t }
                    if dur.isFinite, dur > 0 { m.duration = dur }
                    // Near-end auto-advance.
                    if !self.nearEndFired, dur > 5, t >= dur - 0.35 {
                        self.nearEndFired = true
                        self.onNearEnd?()
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
    var fallbackCount: Int
    var current: Int
    var onPick: (Int) -> Void
    @State private var asc = true
    @Environment(\.dismiss) private var dismiss

    private var episodes: [Episode] {
        if let eps = detail?.episodes, !eps.isEmpty {
            return asc ? eps : Array(eps.reversed())
        }
        let n = detail?.episode_count ?? fallbackCount
        guard n > 0 else { return [] }
        let generated = (1...n).map { Episode(ep_num: $0, title: "第\($0)集", duration: 0, status: 1) }
        return asc ? generated : Array(generated.reversed())
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if episodes.isEmpty {
                    Text("暂无剧集")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(episodes) { ep in
                            Button {
                                onPick(ep.ep_num)
                                dismiss()
                            } label: {
                                Text("\(ep.ep_num)")
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        ep.ep_num == current ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                            }
                        }
                    }
                    Text("点选即切换播放")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(detail?.title ?? "选集")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(asc ? "倒序" : "正序") { asc.toggle() }
                }
            }
        }
    }
}
