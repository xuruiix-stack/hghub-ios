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

// MARK: - Fetch bytes (mirrors net::fetch_bytes: Referer=<base>/, 20s timeout)

final class ByteFetcher: @unchecked Sendable {
    private let lazySession: URLSession
    private let baseProvider: @Sendable () -> String

    init(baseProvider: @escaping @Sendable () -> String) {
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
        req.setValue("\(baseProvider())/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await lazySession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.network("HTTP \(code)") }
        let mime = (resp as? HTTPURLResponse)?.mimeType
        return (mime, data)
    }
}

public final class HLSProxy: NSObject, ObservableObject {
    static let shared = HLSProxy()

    public var base: String {
        "http://127.0.0.1:\(port)"
    }

    private var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "hg.hlsproxy", qos: .utility)
    private let fetcher: ByteFetcher
    private let plCache = NSCache<NSString, NSString>()
    private let session = URLSession(configuration: .default)

    override init() {
        fetcher = ByteFetcher { MainActor.assumeIsolated { API.shared.base } }
        super.init()
        start()
    }

    private func start() {
        let params = NWParameters.tcp
        listener = try? NWListener(using: params)
        listener?.service = NWListener.Service(name: "hg-hls", type: "_http._tcp")
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handle(conn: conn)
        }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                if let port = self?.listener?.port?.rawValue {
                    self?.port = port
                }
            }
        }
        listener?.start(queue: queue)
    }

    // --- connection handling ---

    private func handle(conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let data = data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let path = Self.parsePath(req)
            Task {
                await self?.route(path: path, conn: conn)
            }
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
        var u = path
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
        if let hit = plCache.object(forKey: url as NSString) { return hit as String }
        let (_, data) = try await fetcher.fetch(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw APIError.network("播放列表不是 UTF-8 文本")
        }
        let cleaned = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        guard cleaned.hasPrefix("#EXTM3U") else { throw APIError.network("响应不是 HLS 播放列表") }
        let rewritten = rewritePlaylist(baseURL: url, text: cleaned, prefix: base)
        if plCache.countLimit == 0 { plCache.countLimit = 60 }
        plCache.setObject(rewritten as NSString, forKey: url as NSString)
        return rewritten
    }

    private func respond(_ conn: NWConnection, status: Int, body: Data, contentType: String, cache: String) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 502: "Bad Gateway"][status] ?? "Error"
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
        conn.send(content: full, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
