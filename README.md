# HGhub (iOS)

Native iOS rebuild of Minireel/HGhub (PolyForm Noncommercial 1.0.0, personal non-commercial use only).
Swift / SwiftUI, Xcode project, iOS deployment target **16.4**, arm64, bundle id **com.minireel.hghub**.

## Open & build (macOS)

1. Open `HGhub.xcodeproj` in Xcode 15+ on macOS.
2. Set your **Team** (or build unsigned for TrollStore sideload).
3. Run on a device (iOS 16.4+). For TrollStore: archive → IPA (or `-allowProvisioningUpdates` off) → install via TrollStore.

## Structure

- `HGhub/HGhubApp.swift` — app entry
- `HGhub/Models/Models.swift` — types mirroring `src/types.ts`
- `HGhub/Networking/Network.swift` — edge envelope (`POST /api/edge/request`), session, lines/mirrors, update check
- `HGhub/Media/Media.swift` — AES-128-CBC cover decryption + HLS playlist rewrite helpers
- `HGhub/Media/HLSProxy.swift` — loopback proxy (`/hls`, `/seg`, `/img`) mirroring Rust `media.rs`
- `HGhub/Store/AppStore.swift` — local likes/favs/history/follows persistence
- `HGhub/Views/ContentView.swift` — home vertical feed + AVPlayer page
- `HGhub/Views/Pages.swift` — Search / Rank / Category / Posts / Profile / Settings / Lines / Login

## Notes

- Default line: https://huangguoai.com (changeable in Settings → 线路).
- Guest browsing works without login; login/register only on trusted fixed lines.
- No payment / VIP / ads (the original has none).
