import AVFoundation
import SwiftUI
import UIKit

// MARK: - Player feature layer (ported from LNPANDY v1.2.2 + hghubx behaviors)
//
// Native player route stays untouched: AVPlayer + local NWListener HLS proxy.
// This file only adds the interaction layer around it:
//   P0: auto-next-episode, long-press 2x (+slide-up lock), horizontal
//       drag-to-seek, native landscape fullscreen (UIWindowScene
//       .requestGeometryUpdate, iOS 16.0+), playback lock, mirror probing
//       polish; draggable progress bar.
//   P1: pinch zoom (1x–3.5x) + pan, single-tap clean mode, double-tap pause.
// All APIs are iOS 16.4 / Swift 5.0 compatible. No iOS 17+ APIs.

// MARK: - Native orientation control (mirrors api.rs set_orientation)

/// Requests a portrait/landscape geometry update on the key window scene.
/// LNPANDY does this via hand-rolled objc_msgSend FFI; in Swift we can call
/// UIWindowScene.requestGeometryUpdate(_:errorHandler:) directly (iOS 16+,
/// deployment target is 16.4 so it is available without availability checks).
enum OrientationController {
    /// Mask values mirror UIInterfaceOrientationMask:
    /// portrait = 1 << 1, landscapeRight = 1 << 3 (LNPANDY uses the same).
    static func requestLandscape(_ landscape: Bool) {
        let mask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        DispatchQueue.main.async {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.session.role == .windowApplication }) ?? scenes.first else {
                return
            }
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(prefs) { error in
                // Non-fatal: rotation is best-effort; the player keeps playing
                // regardless of whether the system honors the request.
                print("[orientation] geometry update failed: \(error.localizedDescription)")
            }
        }
    }

    static var isDeviceLandscape: Bool {
        UIWindowScene.currentInterfaceOrientation.isLandscape
    }
}

extension UIWindowScene {
    /// Current interface orientation of the key window scene, falling back
    /// to the device orientation when the scene is not available yet.
    static var currentInterfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.session.role == .windowApplication }) ?? scenes.first else {
            return UIInterfaceOrientation.unknown
        }
        return scene.interfaceOrientation
    }
}

// MARK: - Playback lock (mirrors PlaybackLock.tsx)

/// Full-screen invisible shield that eats every touch while locked; only a
/// semi-transparent unlock button remains interactive. Does not pause media.
struct PlaybackLockOverlay: View {
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            // Inert shield: swallows all gestures below it.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: onUnlock) {
                        Image(systemName: "lock.open")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel("解锁播放控制")
                    .padding(.trailing, 16)
                }
                .padding(.top, 60)
                Spacer()
            }
        }
        .background(Color.clear)
        .onTapGesture { /* eat taps; unlock only via the button */ }
    }
}

// MARK: - Fullscreen player overlay (mirrors Feed.tsx fs-immersive stage)

/// Landscape fullscreen stage: black background, the live AVPlayerLayer
/// re-hosted here, immersive control bar (exit / lock / play-pause /
/// progress bar / speed), scrub overlay, rate HUD. The player view itself
/// stays owned by FeedPage; only the AVPlayerLayer moves into this overlay
/// via PlayerLayerHost so playback never restarts across the transition.
struct FullscreenPlayerOverlay: View {
    @ObservedObject var model: PlayerGestureModel
    var onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerLayerHost(model: model)
                .ignoresSafeArea()

            // scrub preview (horizontal drag anywhere)
            if let scrub = model.scrub {
                VStack(spacing: 6) {
                    Text(fmtTime(scrub.target))
                        .font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text("/ \(fmtTime(model.duration))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    Capsule().fill(Color.white.opacity(0.25))
                        .frame(width: 200, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white)
                                .frame(width: max(1, 200 * scrub.target / max(model.duration, 1)), height: 3)
                        }
                }
                .foregroundStyle(.white)
                .padding(20)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }

            // rate HUD
            if model.holdSpeed || model.speedLocked {
                VStack(spacing: 4) {
                    Text("2.0x").font(.system(size: 15, weight: .bold))
                    Text(model.speedLocked ? "已锁定 · 点按解除" : "倍速中 · 松开恢复")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(model.speedLocked ? .yellow : .white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.45), in: Capsule())
                .onTapGesture { model.speedLocked = false }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 46)
                .allowsHitTesting(true)
            }

            // hold-to-lock hint
            if model.holdSpeed && !model.lockArmed {
                Label("上滑锁定倍速", systemImage: "lock")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(y: -40)
                    .allowsHitTesting(false)
            }
            if model.holdSpeed && model.lockArmed {
                Label("松开锁定 2.0x", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .offset(y: -40)
                    .allowsHitTesting(false)
            }

            if model.controlsLocked {
                PlaybackLockOverlay { model.controlsLocked = false }
            } else {
                fullscreenControls
            }
        }
        .statusBarHidden()
    }

    private var fullscreenControls: some View {
        VStack {
            // top bar: lock + exit
            HStack(spacing: 12) {
                Button { model.controlsLocked = true } label: {
                    Image(systemName: "lock")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("锁定播放控制")
                Button(action: onExit) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                .accessibilityLabel("退出全屏")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            // bottom bar: play/pause, time, progress, rate
            VStack(spacing: 6) {
                PlayerProgressBar(model: model)
                HStack(spacing: 12) {
                    Button { model.togglePlay() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
                    Text(fmtTime(model.currentTime))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button {
                        model.cycleRate()
                    } label: {
                        Text(String(format: "%.2gx", model.baseRate))
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(model.baseRate != 1 ? .yellow : .white)
                    }
                    .accessibilityLabel("切换倍速")
                    Text(fmtTime(model.duration))
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 14)
        }
    }
}

// MARK: - Draggable progress bar (mirrors Feed.tsx onBarDown/Move/Up)

struct PlayerProgressBar: View {
    @ObservedObject var model: PlayerGestureModel

    var body: some View {
        GeometryReader { geo in
            let pct = model.barPct ?? (model.duration > 0 ? model.currentTime / model.duration : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                    .frame(height: model.barPct != nil ? 5 : 3)
                Capsule().fill(.white)
                    .frame(width: max(0, geo.size.width * pct), height: model.barPct != nil ? 5 : 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        model.barScrubbing = true
                        model.barPct = min(1, max(0, g.location.x / max(geo.size.width, 1)))
                    }
                    .onEnded { g in
                        let pct = min(1, max(0, g.location.x / max(geo.size.width, 1)))
                        model.barPct = nil
                        model.barScrubbing = false
                        if model.duration > 0 {
                            model.seek(to: pct * model.duration, source: "bar")
                        }
                    }
            )
            .overlay(alignment: .top) {
                if model.barPct != nil {
                    Text("\(fmtTime((model.barPct ?? 0) * model.duration)) / \(fmtTime(model.duration))")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .offset(y: -26)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 16)
    }
}

// MARK: - AVPlayerLayer re-host (keeps playback alive across fullscreen)

/// Hosts the *same* AVPlayerLayer instance the feed player uses. Moving one
/// AVPlayerLayer between superlayers does not interrupt playback (mirrors
/// LNPANDY's fixed fullscreen stage + keepPlayingThroughTransition rationale
/// and stclock1988/hghub-ios PlayerView keepPlayingThroughTransition).
struct PlayerLayerHost: UIViewRepresentable {
    @ObservedObject var model: PlayerGestureModel

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let v = PlayerLayerContainerView(frame: .zero)
        return v
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        if let layer = model.playerLayer, layer !== uiView.hostedLayer {
            uiView.host(layer)
        }
        uiView.applyZoom(scale: model.zoomScale,
                         panX: model.zoomPanX, panY: model.zoomPanY,
                         gesturing: model.zoomGesturing)
    }
}

final class PlayerLayerContainerView: UIView {
    var hostedLayer: CALayer?

    func host(_ layer: CALayer) {
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = layer
        layer.frame = bounds
        if layer.superlayer !== self.layer {
            self.layer.insertSublayer(layer, at: 0)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedLayer?.frame = bounds
    }

    func applyZoom(scale: CGFloat, panX: CGFloat, panY: CGFloat, gesturing: Bool) {
        guard let hostedLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hasTransform = scale != 1 || panX != 0 || panY != 0
        hostedLayer.setAffineTransform(
            hasTransform
                ? CGAffineTransform(translationX: panX, y: panY).scaledBy(x: scale, y: scale)
                : .identity)
        CATransaction.commit()
    }
}

// MARK: - Gesture model (mirrors Feed.tsx gesture state machine)

/// Observable bridge between UIKit gestures (installed on the player
/// container) and SwiftUI overlays. One instance per active FeedPage player.
final class PlayerGestureModel: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var controlsLocked = false
    @Published var cleanMode = false

    // long-press 2x
    @Published var holdSpeed = false
    @Published var speedLocked = false
    @Published var lockArmed = false
    @Published var baseRate: Float = 1

    // horizontal drag seek
    struct ScrubState {
        var target: Double
    }
    @Published var scrub: ScrubState?

    // progress bar
    @Published var barPct: Double?
    @Published var barScrubbing = false

    // pinch zoom
    @Published var zoomScale: CGFloat = 1
    @Published var zoomPanX: CGFloat = 0
    @Published var zoomPanY: CGFloat = 0
    @Published var zoomGesturing = false

    // double-tap pause / single-tap clean
    @Published var showPauseBadge = false

    /// The live AVPlayerLayer owned by the feed player's container view.
    /// Set from CoverPlayerView whenever the player is (re)built.
    weak var playerLayer: AVPlayerLayer?
    var player: AVPlayer? { playerLayer?.player }
    var onTogglePlay: (() -> Void)?
    var onSeek: ((Double, String) -> Void)?
    var onRateChange: ((Float) -> Void)?

    // MARK: gesture plumbing (called from UIKit recognizers)

    private var scrubBaseTime: Double = 0
    private var scrubStartX: CGFloat = 0
    private var scrubWidth: CGFloat = 0
    private var holdStartY: CGFloat = 0

    func attach(to view: UIView) {
        // Long press → 2x hold
        let longPress = UILongPressGestureRecognizer(target: self,
            action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.38 // mirrors Feed.tsx 380ms
        longPress.allowableMovement = 64
        view.addGestureRecognizer(longPress)

        // Horizontal pan → seek (used when hold is not active)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)

        // Single tap → clean mode; double tap → pause/play
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = self
        view.addGestureRecognizer(singleTap)

        // Pinch → zoom
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        // Two-finger pan → pan while zoomed
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.delegate = self
        view.addGestureRecognizer(twoFingerPan)
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard !controlsLocked else { return }
        switch g.state {
        case .began:
            holdStartY = g.location(in: g.view).y
            holdSpeed = true
            lockArmed = false
            onRateChange?(2)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            // Slide up > 64pt while holding → arm the 2x lock.
            let up = holdStartY - g.location(in: g.view).y
            lockArmed = up > 64
        case .ended:
            holdSpeed = false
            if lockArmed {
                speedLocked = true
            }
            lockArmed = false
            onRateChange?(speedLocked ? 2 : baseRate)
        case .cancelled, .failed:
            holdSpeed = false
            lockArmed = false
            onRateChange?(speedLocked ? 2 : baseRate)
        default:
            break
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard !controlsLocked, !holdSpeed else { return }
        let view = g.view ?? UIView()
        switch g.state {
        case .began:
            scrubStartX = g.location(in: view).x
            scrubWidth = max(1, view.bounds.width)
            scrubBaseTime = currentTime
            scrub = ScrubState(target: scrubBaseTime)
        case .changed:
            guard duration > 0 else { return }
            let dx = g.location(in: view).x - scrubStartX
            // Full width ≈ full duration (mirrors Feed.tsx dx/width * total).
            let target = min(max(0, scrubBaseTime + Double(dx / scrubWidth) * duration),
                             max(0, duration - 0.2))
            scrub = ScrubState(target: target)
        case .ended:
            if let s = scrub {
                seek(to: s.target, source: "gesture")
            }
            scrub = nil
        case .cancelled, .failed:
            scrub = nil
        default:
            break
        }
    }

    @objc private func handleSingleTap(_ g: UITapGestureRecognizer) {
        guard !controlsLocked else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            cleanMode.toggle()
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard !controlsLocked else { return }
        togglePlay()
    }

    private var pinchStartScale: CGFloat = 1
    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard !controlsLocked else { return }
        switch g.state {
        case .began:
            pinchStartScale = zoomScale
            zoomGesturing = true
        case .changed:
            // 1x ~ 3.5x (mirrors Feed.tsx clamp)
            zoomScale = min(3.5, max(1, pinchStartScale * g.scale))
        case .ended, .cancelled:
            zoomGesturing = false
            if zoomScale < 1.08 { // snap back (mirrors <1.08 rule)
                zoomScale = 1
                zoomPanX = 0
                zoomPanY = 0
            }
        default:
            break
        }
    }

    private var panStart = CGPoint.zero
    private var panStartOffset = CGPoint.zero
    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        guard !controlsLocked else { return }
        let view = g.view ?? UIView()
        switch g.state {
        case .began:
            panStart = g.location(in: view)
            panStartOffset = CGPoint(x: zoomPanX, y: zoomPanY)
            zoomGesturing = true
        case .changed:
            let loc = g.location(in: view)
            let dx = loc.x - panStart.x + panStartOffset.x
            let dy = loc.y - panStart.y + panStartOffset.y
            // Clamp pan to the zoomed-overrun (mirrors 0.55 factor).
            let maxX = max(0, (zoomScale - 1) * view.bounds.width * 0.55)
            let maxY = max(0, (zoomScale - 1) * view.bounds.height * 0.55)
            zoomPanX = min(maxX, max(-maxX, dx))
            zoomPanY = min(maxY, max(-maxY, dy))
        case .ended, .cancelled:
            zoomGesturing = false
        default:
            break
        }
    }

    // MARK: commands

    func togglePlay() {
        onTogglePlay?()
    }

    func seek(to t: Double, source: String) {
        onSeek?(t, source)
    }

    func cycleRate() {
        // 1 → 1.25 → 1.5 → 2 → 1 (mirrors Feed.tsx cycleRate)
        let seq: [Float] = [1, 1.25, 1.5, 2]
        let idx = seq.firstIndex(of: baseRate) ?? 0
        baseRate = seq[(idx + 1) % seq.count]
        speedLocked = false
        onRateChange?(baseRate)
    }

    func resetForNewMedia() {
        currentTime = 0
        duration = 0
        scrub = nil
        barPct = nil
        barScrubbing = false
        zoomScale = 1
        zoomPanX = 0
        zoomPanY = 0
        holdSpeed = false
        speedLocked = false
        lockArmed = false
    }
}

extension PlayerGestureModel: UIGestureRecognizerDelegate {
    /// Pan recognizer only claims clearly-horizontal drags; otherwise the
    /// vertical feed pager must keep working. Long-press owns its own
    /// interaction once it fires (holdSpeed).
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch + two-finger pan must work together.
        if gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer {
            return true
        }
        return false
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer,
           pan.minimumNumberOfTouches == 1, pan.maximumNumberOfTouches == 1 {
            let v = pan.velocity(in: pan.view)
            // Only horizontal pans (mirror Feed.tsx: |dx| > 1.2×|dy|).
            return abs(v.x) > abs(v.y) * 1.2 && abs(v.x) > 120
        }
        return true
    }
}
