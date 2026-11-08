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

    func fetch(_ url: String) async throws -> (mime: String?, data: Data) {
        guard let u = URL(string: url) else { throw APIError.network("地址无效") }
        var req = URLRequest(url: u)
        req.setValue("\(await baseProvider())/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await lazySession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.network("HTTP \(code)") }
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

    public var isReady: Bool { port != 0 }

    public var base: String {
        "http://127.0.0.1:\(port)"
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hg.hlsproxy", qos: .utility)
    private let fetcher: ByteFetcher
    private let plCache = NSCache<NSString, NSString>()
    private let plCacheDates = NSCache<NSString, NSDate>()
    private let plCacheTTL: TimeInterval = 10 * 60

    override init() {
        fetcher = ByteFetcher { await MainActor.run { API.shared.base } }
        super.init()
        start()
    }

    /// Suspends until the listener is bound (or gives up after 5s). The
    /// playback path awaits this before building any proxy URL — the old
    /// code read `base` synchronously right after `start()`, so a slow
    /// bind produced `http://127.0.0.1:0/...` URLs and a black player.
    public func waitUntilReady() async {
        let deadline = Date().addingTimeInterval(5)
        while !isReady && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func start() {
        let params = NWParameters.tcp
        listener = try? NWListener(using: params)
        // Note: no Bonjour service type — advertising to the (nonexistent,
        // sandboxed) Bonjour daemon can fail the bind on hardened builds
        // and the player only ever dials 127.0.0.1 directly.
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn: conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let port = self?.listener?.port?.rawValue {
                    self?.portLock.lock()
                    self?._port = port
                    self?.portLock.unlock()
                }
            }
        }
        listener?.start(queue: queue)
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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
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
                respond(conn, status: 502, body: (error.localizedDescription).data(using: .utf8)!, contentType: "text/plain", cache: "no-store")
            }
        case "/hls":
            do {
                let text = try await loadPlaylist(url: target)
                respond(conn, status: 200, body: Data(text.utf8), contentType: "application/vnd.apple.mpegurl", cache: "no-store")
            } catch {
                respond(conn, status: 502, body: (error.localizedDescription).data(using: .utf8)!, contentType: "text/plain", cache: "no-store")
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
                respond(conn, status: 502, body: (error.localizedDescription).data(using: .utf8)!, contentType: "text/plain", cache: "no-store")
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

    private func loadPlaylist(url: String) async throws -> String {
        if let hit = plCache.object(forKey: url as NSString),
           let when = plCacheDates.object(forKey: url as NSString),
           Date().timeIntervalSince(when as Date) < plCacheTTL {
            return hit as String
        }
        let (_, data) = try await fetcher.fetch(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.network("播放列表不是 UTF-8 文本")
        }
        let cleaned = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        guard cleaned.hasPrefix("#EXTM3U") else { throw APIError.network("响应不是 HLS 播放列表") }
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
        var full = Data((headers + "\r\n").utf8)
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
