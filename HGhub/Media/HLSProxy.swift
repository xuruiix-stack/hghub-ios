import Foundation
import Network

// MARK: - Local HLS proxy (iOS-unreachable-localhost problem solved)
// AVPlayer cannot load an encrypted CDN stream directly when CORS /
// hotlink protection is in play, and iOS has no Tauri-style local scheme.
// This tiny loopback server rewrites m3u8 playlists and proxies keys /
// segments, mirroring media.rs's /hls and /seg endpoints exactly.
//
// The proxy listens on 127.0.0.1 with a high ephemeral port. AVPlayer
// (same process) reaches it via http://127.0.0.1:<port>.

/// Connection-level failure raised by the proxy itself. Mirrors the
/// transport split in media.rs, where `fetch_bytes` (net.rs) returns
/// reqwest errors and the protocol layer only formats them.
enum HLSProxyError: Error, LocalizedError {
    case upstream(String)
    case notReady
    var errorDescription: String? {
        switch self {
        case .upstream(let m): return m
        case .notReady: return "本地代理未就绪，请重试"
        }
    }
}

// MARK: - Structured playback diagnostics

/// One pinpointable playback failure. Surfaces in the "视频暂时无法加载"
/// overlay (FeedPage) so the next failure names the exact failing step,
/// host and HTTP status instead of a bare localizedDescription.
/// Foundation-only so Linux typecheck covers it.
struct PlaybackDiagnostic: Error {
    var step: String        // playlist / key / segment / proxy / item / player
    var host: String        // failing host (upstream CDN host, or 127.0.0.1 for loopback)
    var httpStatus: Int?
    var code: Int?          // NSError code when known (e.g. AVError)
    var domain: String?     // error domain (e.g. AVFoundationErrorDomain)
    var message: String

    func diagnosticString() -> String {
        var s = "【\(step)】\(message)"
        if !host.isEmpty { s += " host=\(host)" }
        if let httpStatus { s += " http=\(httpStatus)" }
        if let domain { s += " domain=\(domain)" }
        if let code, code != 0 { s += " code=\(code)" }
        return s
    }
}

extension PlaybackDiagnostic: LocalizedError {
    var errorDescription: String? { diagnosticString() }
}

/// Diagnose any thrown error into a PlaybackDiagnostic for display.
func diagnoseFailure(_ error: Error, step: String, host: String) -> PlaybackDiagnostic {
    if let d = error as? PlaybackDiagnostic { return d }
    let ns = error as NSError
    let http = httpStatusFromMessage(error.localizedDescription)
    return PlaybackDiagnostic(step: step, host: host, httpStatus: http,
        code: ns.code, domain: ns.domain, message: error.localizedDescription)
}

/// "HTTP 502" embedded in APIError.network messages → 502
func httpStatusFromMessage(_ message: String) -> Int? {
    let parts = message.split(separator: " ")
    guard parts.count >= 2, parts[0] == "HTTP" else { return nil }
    return Int(parts[1])
}

/// URL host, or "" when unparsable.
func hostOf(_ urlString: String) -> String {
    URL(string: urlString)?.host ?? ""
}

/// For a proxy URL (http://127.0.0.1:port/seg?u=<encoded upstream>),
/// recover the upstream host so a CDN failure is blamed on the CDN,
/// not on the loopback proxy.
func upstreamHostOf(_ proxyURLString: String) -> String? {
    guard let u = URL(string: proxyURLString),
          let comp = u.query else { return nil }
    let target = HLSProxy.paramU(comp)
    guard !target.isEmpty else { return nil }
    return URL(string: target)?.host
}

// MARK: - Fetch bytes (mirrors net::fetch_bytes: Referer=<base>/, 20s timeout)

final class ByteFetcher: @unchecked Sendable {
    private let lazySession: URLSession
    private let baseProvider: @Sendable () async -> String

    init(baseProvider: @escaping @Sendable () async -> String) {
        self.baseProvider = baseProvider
        var c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpShouldSetCookies = false
        c.urlCache = nil
        lazySession = URLSession(configuration: c)
    }

    private static let hostOf: (String) -> String = { url in URL(string: url)?.host ?? "" }

    func fetch(_ url: String) async throws -> (mime: String?, data: Data) {
        guard let u = URL(string: url) else { throw APIError.network("地址无效") }
        var req = URLRequest(url: u)
        req.setValue("\(await baseProvider())/", forHTTPHeaderField: "Referer")
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await lazySession.data(for: req)
        } catch {
            let ns = error as NSError
            throw PlaybackDiagnostic(step: "segment", host: Self.hostOf(url),
                httpStatus: nil, code: ns.code, domain: ns.domain,
                message: "CDN 直连失败: \(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw PlaybackDiagnostic(step: "segment", host: Self.hostOf(url),
                httpStatus: code, code: code, domain: "HTTP",
                message: "CDN 返回 HTTP \(code)")
        }
        let mime = (resp as? HTTPURLResponse)?.mimeType
        return (mime, data)
    }
}

public final class HLSProxy: NSObject, ObservableObject {
    static let shared = HLSProxy()

    private var portLock = NSLock()
    private var _port: UInt16 = 0
    /// 0 = not ready (mirrors "listen failed / not started" instead of the
    /// old behaviour of happily returning http://127.0.0.1:0).
    public var port: UInt16 {
        portLock.lock(); defer { portLock.unlock() }
        return _port
    }

    /// True only while the listener is actually bound and accepting.
    /// `port != 0` alone was a lie: `_port` is only ever set on `.ready`
    /// and never cleared, so after a network-path flap (`.waiting`), a
    /// system teardown (`.cancelled`) or a bind failure the flag stayed
    /// true while the socket was dead, and the self-check dialed a dead
    /// port and got a spurious -1004 (loopback unreachable). The flag now
    /// also requires the tracked listener state to be `.ready`.
    public var isReady: Bool {
        guard port != 0 else { return false }
        stateLock.lock()
        let ready = listenerStateIsReady
        stateLock.unlock()
        return ready
    }

    public var base: String {
        "http://127.0.0.1:\(port)"
    }

    private(set) var lastDiagnostic: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastDiagnostic }
        set { stateLock.lock(); _lastDiagnostic = newValue; stateLock.unlock() }
    }
    private var _lastDiagnostic: String?
    private(set) var listenerFailed: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _listenerFailed }
        set { stateLock.lock(); _listenerFailed = newValue; stateLock.unlock() }
    }
    private var _listenerFailed: String?

    /// Truthful mirror of the current NWListener.State, guarded by
    /// stateLock. A listener in `.setup` / `.waiting` / `.failed` /
    /// `.cancelled` is NOT accepting connections, so `isReady` and
    /// `waitUntilReady` must never treat it as live.
    private let stateLock = NSLock()
    private var listenerStateIsReady = false
    /// Identifies the instance `listener` currently points at. State
    /// updates carry the generation they were installed with, so a late
    /// `.cancelled` from a superseded listener (it fires after a newer
    /// listener has already become `.ready`) cannot clear the port or
    /// trigger a restart of a healthy listener.
    private var listenerGeneration = 0
    /// Bounded restart bookkeeping: how many consecutive restarts have been
    /// scheduled since the listener last reached `.ready`, and the earliest
    /// date the next auto-restart may begin.
    private var restartAttempts = 0
    private var restartNotBefore = Date.distantPast

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hg.hlsproxy", qos: .utility)
    private let fetcher: ByteFetcher
    /// One shared self-check session. Force a DIRECT loopback connection:
    /// `connectionProxyDictionary = [:]` bypasses any system-wide HTTP
    /// proxy, which would otherwise divert the 127.0.0.1 request and
    /// produce a spurious -1004. Reused across calls instead of minting a
    /// fresh session (and its connection pool) per self-check.
    private let selfCheckSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.connectionProxyDictionary = [:]
        c.urlCache = nil
        return URLSession(configuration: c)
    }()
    private let plCache = NSCache<NSString, NSString>()
    private let plCacheDates = NSCache<NSString, NSDate>()
    private let plCacheTTL: TimeInterval = 10 * 60

    override init() {
        fetcher = ByteFetcher { await MainActor.run { API.shared.base } }
        super.init()
        start()
    }

    /// Suspends until the listener is truly bound AND accepting (up to
    /// ~8s). If it is not ready, (re)starts it and keeps waiting — a
    /// flapped / torn-down listener heals here instead of handing
    /// AVPlayer a dead port. The playback path awaits this before
    /// building any proxy URL — the old code read `base` synchronously
    /// right after `start()`, so a slow bind produced
    /// `http://127.0.0.1:0/...` URLs and a black player.
    public func waitUntilReady() async {
        let deadline = Date().addingTimeInterval(8)
        while !isReady && Date() < deadline {
            ensureRunning()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// (Re)starts the listener when it is not in `.ready` state. Safe to
    /// call from any thread and any number of times: it no-ops when the
    /// listener is already starting or ready.
    public func ensureRunning() {
        stateLock.lock()
        let ready = listenerStateIsReady
        let starting = listener != nil && !ready && restartNotBefore <= Date()
        stateLock.unlock()
        guard !ready, !starting else { return }
        start()
    }

    /// Schedule an automatic restart after a failed / cancelled
    /// transition, with bounded retries and growing backoff (max ~5
    /// consecutive attempts) so a restart loop can never spin forever.
    /// `restartAttempts` resets to 0 each time the listener reaches
    /// `.ready`.
    private func scheduleRestart() {
        stateLock.lock()
        let attempts = restartAttempts
        guard attempts < 5 else {
            let msg = "【proxy】监听重启已达上限（5 次），停止自动重启"
            stateLock.unlock()
            lastDiagnostic = msg
            return
        }
        let delay = min(0.5 * Double(1 << attempts), 5.0)  // 0.5s, 1s, 2s, 4s, 5s
        restartAttempts = attempts + 1
        restartNotBefore = Date().addingTimeInterval(delay)
        stateLock.unlock()
        lastDiagnostic = "【proxy】监听异常，计划第 \(attempts + 1) 次重启（延迟 \(delay)s）"
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start()
        }
    }

    private func start() {
        let params = NWParameters.tcp
        // No Bonjour service type — advertising to the (nonexistent,
        // sandboxed) Bonjour daemon can fail the bind on hardened builds
        // and the player only ever dials 127.0.0.1 directly.
        guard let l = try? NWListener(using: params) else {
            listenerFailed = "NWListener 创建失败"
            lastDiagnostic = "【proxy】NWListener 创建失败，代理未启动"
            scheduleRestart()
            return
        }
        queue.sync {
            self.listener?.cancel()
            stateLock.lock()
            listenerGeneration += 1
            let gen = listenerGeneration
            listenerStateIsReady = false
            listener = l
            stateLock.unlock()
            portLock.lock()
            _port = 0
            portLock.unlock()
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn: conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                // Ignore transitions from a superseded listener instance.
                self.stateLock.lock()
                let current = self.listenerGeneration
                self.stateLock.unlock()
                guard gen == current else { return }
                switch state {
                case .ready:
                    if let boundPort = l.port?.rawValue, boundPort != 0 {
                        self.portLock.lock()
                        self._port = boundPort
                        self.portLock.unlock()
                    }
                    self.stateLock.lock()
                    self.listenerStateIsReady = true
                    self.restartAttempts = 0
                    self.restartNotBefore = .distantPast
                    self._listenerFailed = nil
                    self.stateLock.unlock()
                    self.lastDiagnostic = "【proxy】监听就绪 port=\(self.port) state=ready"
                case .failed(let err):
                    self.portLock.lock()
                    self._port = 0
                    self.portLock.unlock()
                    self.stateLock.lock()
                    self.listenerStateIsReady = false
                    self.stateLock.unlock()
                    self.listenerFailed = "NWListener 绑定失败: \(err)"
                    self.lastDiagnostic = "【proxy】监听失败 state=failed: \(err)"
                    self.scheduleRestart()
                case .cancelled:
                    // A deliberate teardown (e.g. superseded by a fresh
                    // listener from start()) lands here too. Clear the
                    // port — the socket is gone — but only restart if
                    // this instance is still the current one; a fresh
                    // start() already replaced it, and the generation
                    // check above drops superseded updates before they
                    // get here.
                    self.portLock.lock()
                    self._port = 0
                    self.portLock.unlock()
                    self.stateLock.lock()
                    self.listenerStateIsReady = false
                    self.stateLock.unlock()
                    self.lastDiagnostic = "【proxy】监听已取消 state=cancelled"
                    self.scheduleRestart()
                case .waiting(let err):
                    // Network-path flap: not accepting right now, but it
                    // may recover to .ready on its own. Clear readiness
                    // so callers never trust the stale port, but do not
                    // restart — .ready will follow.
                    self.portLock.lock()
                    self._port = 0
                    self.portLock.unlock()
                    self.stateLock.lock()
                    self.listenerStateIsReady = false
                    self.stateLock.unlock()
                    self.lastDiagnostic = "【proxy】监听等待 state=waiting: \(err)"
                case .setup:
                    self.portLock.lock()
                    self._port = 0
                    self.portLock.unlock()
                    self.stateLock.lock()
                    self.listenerStateIsReady = false
                    self.stateLock.unlock()
                @unknown default:
                    break
                }
            }
        }
        l.start(queue: queue)
    }

    /// After the listener reports ready, prove the loopback proxy serves
    /// before AVPlayer ever sees the URL. A 200 + #EXTM3U body is required;
    /// anything else is reported as a loopback proxy failure (not a CDN
    /// failure) so an unreachable on-device proxy is distinguishable.
    ///
    /// Up to 3 attempts with short backoff (300ms, then 800ms). Before
    /// each attempt the listener is (re)started if needed and awaited, so
    /// a loopback connect failure (-1004) triggers a restart and a retry
    /// instead of failing the video on a transient flap.
    public func selfCheck(playlistProxyURL: String) async throws {
        var lastError: PlaybackDiagnostic?
        let backoffs: [UInt64] = [300_000_000, 800_000_000]
        for attempt in 0..<3 {
            ensureRunning()
            if let failed = listenerFailed, !isReady {
                lastError = PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                    httpStatus: nil, code: nil, domain: nil,
                    message: "代理监听失败: \(failed)")
            } else if let url = URL(string: playlistProxyURL) {
                do {
                    try await selfCheckOnce(url: url)
                    return
                } catch let d as PlaybackDiagnostic {
                    lastError = d
                    // Loopback connect failure means the listener flapped
                    // after we read the port; heal it before retrying.
                    if d.step == "proxy" { ensureRunning() }
                }
            } else {
                lastError = PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                    httpStatus: nil, code: nil, domain: nil,
                    message: "代理未就绪（port=\(port)）")
            }
            if attempt < 2 {
                await waitUntilReady()
                try? await Task.sleep(nanoseconds: backoffs[attempt])
            }
        }
        throw lastError ?? PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
            httpStatus: nil, code: nil, domain: nil,
            message: "代理自检失败")
    }

    private func selfCheckOnce(url: URL) async throws {
        guard isReady else {
            throw PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                httpStatus: nil, code: nil, domain: nil,
                message: "代理未就绪（port=\(port)）")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await selfCheckSession.data(for: req)
        } catch {
            let ns = error as NSError
            throw PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                httpStatus: nil, code: ns.code, domain: ns.domain,
                message: "代理自检请求失败（loopback 不可达）: \(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let head = String(data: data.prefix(8), encoding: .utf8) ?? ""
        guard code == 200, head.hasPrefix("#EXTM3U") else {
            throw PlaybackDiagnostic(step: "proxy", host: "127.0.0.1",
                httpStatus: code, code: code, domain: "HTTP",
                message: "代理自检未返回播放列表 (http=\(code), body=\(data.count) bytes, head=\(head))")
        }
        lastDiagnostic = "【proxy】自检通过 port=\(port) bytes=\(data.count)"
    }

    // --- connection handling ---

    private func handle(conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn: conn, buffer: Data())
    }

    /// The request head can exceed one 8192-byte receive (long signed CDN
    /// URLs, Range/Cookie headers). Loop until the header terminator
    /// arrives instead of failing on a truncated request line.
    private func receive(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, ctx, isComplete, error in
            if let error {
                // Peer closed / reset mid-request: stop recursing. The old
                // code ignored isComplete/error and re-issued receive
                // forever on a dead connection.
                conn.cancel()
                return
            }
            if isComplete, data == nil {
                conn.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            let marker = Data("\r\n\r\n".utf8)
            if buffer.range(of: marker) != nil,
               let req = String(data: buffer, encoding: .utf8) {
                let path = Self.parsePath(req)
                Task {
                    await self?.route(path: path, conn: conn)
                }
                return
            }
            if buffer.count > 262144 {
                conn.cancel()
                return
            }
            if isComplete {
                conn.cancel()
                return
            }
            self?.receive(conn: conn, buffer: buffer)
        }
    }

    static func parsePath(_ req: String) -> String {
        // Request line: "GET /hls?u=... HTTP/1.1"
        if let first = req.components(separatedBy: "\r\n").first {
            let parts = Array(first.split(separator: " "))
            if parts.count >= 2 {
                return String(parts[1])
            }
        }
        return "/"
    }

    private func route(path: String, conn: NWConnection) async {
        // Strip query into parts
        let parts = path.split(separator: "?", maxSplits: 1)
        let routePath = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : ""
        let target = Self.paramU(query)
        guard !target.isEmpty else {
            respond(conn, status: 400, body: Data("missing u".utf8), contentType: "text/plain", cache: "no-store")
            return
        }
        switch routePath {
        case "/img":
            do {
                let (mime, data) = try await CoverLoader.shared.loadImage(url: target)
                respond(conn, status: 200, body: data, contentType: mime, cache: "public, max-age=86400")
            } catch {
                recordFailure(error, step: "img", host: hostOf(target))
                respond502(conn: conn, error: error, step: "img", host: hostOf(target))
            }
        case "/hls":
            do {
                let text = try await loadPlaylist(url: target)
                respond(conn, status: 200, body: Data(text.utf8), contentType: "application/vnd.apple.mpegurl", cache: "no-store")
            } catch {
                recordFailure(error, step: "playlist", host: hostOf(target))
                respond502(conn: conn, error: error, step: "playlist", host: hostOf(target))
            }
        case "/seg":
            do {
                let (mime, data) = try await fetcher.fetch(target)
                // Nested playlists returned through /seg are recursively rewritten (mirrors segment_response).
                let isPlaylist = mime?.lowercased().contains("mpegurl") == true
                    || data.starts(with: "#EXTM3U".utf8)
                    || data.starts(with: [0xef, 0xbb, 0xbf, 0x23, 0x45, 0x58, 0x54, 0x4d, 0x33, 0x55])
                if isPlaylist, let text = String(data: data, encoding: .utf8) {
                    let rewritten = rewritePlaylist(baseURL: target, text: text, prefix: base)
                    respond(conn, status: 200, body: Data(rewritten.utf8), contentType: "application/vnd.apple.mpegurl", cache: "no-store")
                } else {
                    respond(conn, status: 200, body: data, contentType: mime ?? "application/octet-stream", cache: "public, max-age=3600")
                }
            } catch {
                recordFailure(error, step: "segment", host: hostOf(target))
                respond502(conn: conn, error: error, step: "segment", host: hostOf(target))
            }
        default:
            respond(conn, status: 404, body: Data("not found".utf8), contentType: "text/plain", cache: "no-store")
        }
    }

    static func paramU(_ query: String) -> String {
        for kv in query.split(separator: "&") where kv.hasPrefix("u=") {
            let v = String(kv.dropFirst(2))
            return v.removingPercentEncoding ?? v
        }
        return ""
    }

    private func recordFailure(_ error: Error, step: String, host: String) {
        lastDiagnostic = diagnoseFailure(error, step: step, host: host).diagnosticString()
    }

    /// 502 body carries the structured diagnostic so AVPlayer's item.error
    /// (and our self-check) can name the failing host instead of a bare
    /// "HTTP 502".
    private func respond502(conn: NWConnection, error: Error, step: String, host: String) {
        let diag = diagnoseFailure(error, step: step, host: host)
        respond(conn, status: 502, body: Data(diag.diagnosticString().utf8),
                contentType: "text/plain", cache: "no-store")
    }

    private func loadPlaylist(url: String) async throws -> String {
        if let hit = plCache.object(forKey: url as NSString),
           let when = plCacheDates.object(forKey: url as NSString),
           Date().timeIntervalSince(when as Date) < plCacheTTL {
            return hit as String
        }
        let (_, data) = try await fetcher.fetch(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PlaybackDiagnostic(step: "playlist", host: hostOf(url),
                httpStatus: nil, code: nil, domain: nil, message: "播放列表不是 UTF-8 文本")
        }
        let cleaned = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        guard cleaned.hasPrefix("#EXTM3U") else {
            throw PlaybackDiagnostic(step: "playlist", host: hostOf(url),
                httpStatus: nil, code: nil, domain: nil, message: "响应不是 HLS 播放列表")
        }
        let rewritten = rewritePlaylist(baseURL: url, text: cleaned, prefix: base)
        if plCache.countLimit == 0 { plCache.countLimit = 60 }
        plCache.setObject(rewritten as NSString, forKey: url as NSString)
        plCacheDates.setObject(NSDate(), forKey: url as NSString)
        return rewritten
    }

    private func respond(_ conn: NWConnection, status: Int, body: Data, contentType: String, cache: String) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: \(cache)",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "", ""
        ].joined(separator: "\r\n")
        // The joined header block already ends with "\r\n\r\n". Appending
        // another "\r\n" here used to shift the body by 2 bytes relative
        // to Content-Length (AVPlayer got "\r\n" + body minus the last
        // 2 bytes: unparseable m3u8, corrupted AES key, lost TS sync).
        var full = Data(headers.utf8)
        full.append(body)
        sendAll(conn: conn, data: full)
    }

    /// Walk the buffer in chunks rather than relying on a single send
    /// that a slow peer might truncate — the Rust side returns the full
    /// Vec<u8> body and AVPlayer issues ranged reads.
    private func sendAll(conn: NWConnection, data: Data) {
        sendAll(conn: conn, data: data, offset: 0)
    }

    private func sendAll(conn: NWConnection, data: Data, offset: Int) {
        guard offset < data.count else {
            conn.cancel()
            return
        }
        let end = min(offset + 65536, data.count)
        conn.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { _ in
            self.sendAll(conn: conn, data: data, offset: end)
        })
    }
}
