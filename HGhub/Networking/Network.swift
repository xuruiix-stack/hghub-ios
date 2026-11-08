import Foundation

// MARK: - Errors

public enum APIError: LocalizedError {
    case network(String)
    case unauthorized
    case server(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return m
        case .unauthorized: return "401"
        case .server(let m): return m
        case .decoding(let m): return m
        }
    }
}

// MARK: - Edge envelope (mirrors net.rs edge)

/// All /api/** calls are folded into one POST envelope:
/// POST {base}/api/edge/request
/// Body: {"method":"GET"|"POST","path":"...","body":"<base64>","content_type":"..."}
/// Header: Authorization: Bearer <token> when authenticated.
public struct EdgeEnvelope: Encodable {
    var method: String
    var path: String
    var body: String
    var content_type: String
}

public struct EdgeResponse<T: Decodable>: Decodable {
    var status: Int?
    var data: T?
    var msg: String?
}

// MARK: - Line / base (mirrors net.rs + lines.rs)

public enum HGLine {
    public static let defaultBase = "https://huangguoai.com"
    public static let fixed: [(name: String, url: String)] = [
        ("固定线路 1", "https://huangguoai.com"),
        ("固定线路 2", "https://huangguoai.ai"),
    ]
    public static let trustedAuthOrigins: Set<String> = ["https://huangguoai.com", "https://huangguoai.ai"]
    public static let publishPage = "https://huangguoai.pages.dev/"
    public static let mirrorMax = 60

    public static func normalizeBase(_ raw: String) -> String? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "https",
              comps.host != nil,
              comps.query == nil, comps.fragment == nil,
              (comps.path == "/" || comps.path.isEmpty) else { return nil }
        var c = comps; c.path = ""
        return c.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func trustedAuth(_ origin: String) -> Bool {
        trustedAuthOrigins.contains(origin)
    }
}

public struct LineItem: Decodable, Identifiable {
    public var name: String?
    public var url: String
    public var host: String?
    public var id: String { url }
}

public struct LineState: Decodable {
    public var base: String
    public var `default`: String
    public var fixed: [LineItem]
}

public struct LineMirrors: Decodable {
    public var source: String
    public var script: String?
    public var items: [LineItem]
}

public struct LineProbe: Decodable {
    public var url: String
    public var ok: Bool
    public var status: Int?
    public var ms: Int
    public var error: String?
}

// MARK: - Session (mirrors session.rs)

public struct Session: Codable {
    public var origin: String = ""
    public var token: String = ""
    public var user: Data? // raw JSON preserved; decoded lazily

    public enum CodingKeys: String, CodingKey { case origin, token, user }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        if let d = try c.decodeIfPresent(JSONValue.self, forKey: .user)?.raw {
            user = d
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(origin, forKey: .origin)
        try c.encode(token, forKey: .token)
        if let u = user { try c.encode(JSONValue(raw: u), forKey: .user) }
    }
    public var decodedUser: User? {
        guard let u = user else { return nil }
        return try? JSONDecoder().decode(User.self, from: u)
    }
}

struct JSONValue: Codable {
    var raw: Data
    init(raw: Data) { self.raw = raw }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        raw = try JSONEncoder().encode(c.decode(DynamicJSON.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(try JSONDecoder().decode(DynamicJSON.self, from: raw))
    }
}

enum DynamicJSON: Codable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([DynamicJSON]), object([String: DynamicJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([DynamicJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: DynamicJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad json")
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

@MainActor
public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()
    private let file: URL
    @Published public private(set) var session: Session

    public init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = dir.appendingPathComponent("session.json")
        session = Session()
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return }
        // Legacy sessions without origin are not assigned to the current line.
        guard !s.origin.isEmpty else { return }
        session = s
    }

    public func token(for origin: String) -> String? {
        (session.origin == origin && !session.token.isEmpty) ? session.token : nil
    }
    public func user(for origin: String) -> User? {
        (session.origin == origin && !session.token.isEmpty) ? session.decodedUser : nil
    }
    public func set(origin: String, token: String, user: User?) {
        session.origin = origin
        session.token = token
        session.user = user.flatMap { try? JSONEncoder().encode($0) }
        persist()
    }
    public func clear() {
        session.origin = ""; session.token = ""; session.user = nil
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: file)
        }
    }
}

// MARK: - API client

@MainActor
public final class API: ObservableObject {
    public static let shared = API()

    @Published public var base: String = HGLine.defaultBase
    @Published public var user: User?
    @Published public var loggedIn: Bool = false
    @Published public var strictSecurity: Bool = true
    @Published public var lastError: String?

    private let session = SessionStore.shared
    private lazy var urlSession: URLSession = {
        var c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    public init() { loadBase() }

    // --- persistence (line.json in documents dir, mirrors net::bind_base) ---

    private var baseFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("line.json")
    }
    private func loadBase() {
        if let data = try? Data(contentsOf: baseFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let b = obj["base"], let n = HGLine.normalizeBase(b) {
            base = n
        }
    }
    public func setBase(_ url: String) throws {
        guard let n = HGLine.normalizeBase(url) else {
            throw APIError.network("线路地址无效（需要纯 HTTPS 站点地址）")
        }
        if n != base { session.clear() }
        base = n
        if let data = try? JSONSerialization.data(withJSONObject: ["base": n]) {
            try? data.write(to: baseFile)
        }
        refreshUser()
    }

    public func refreshUser() {
        user = session.user(for: base)
        loggedIn = session.token(for: base) != nil
    }

    // --- edge ---

    /// Mirrors net::edge: single POST envelope, 3 attempts for body-less GET,
    /// no auto redirect following (URLSession default handles it; we keep default
    /// for simplicity — the Rust side manually re-checks each hop),
    /// 401/403 → "401", status==1 extracts data else msg.
    private func edge<T: Decodable>(
        method: String, path: String, body: [String: Any]? = nil, token: String? = nil
    ) async throws -> T {
        let origin = base
        if strictSecurity,
           (token != nil || path.contains("loginByPassword") || path.contains("registerByPassword")),
           !HGLine.trustedAuth(origin) {
            throw APIError.network("镜像线路仅供游客浏览；登录/注册请切换到固定线路")
        }
        let (encoded, ctype): (String, String) = try {
            guard let body else { return ("", "") }
            let data = try JSONSerialization.data(withJSONObject: body)
            return (data.base64EncodedString(), "application/json")
        }()
        let envelope = EdgeEnvelope(method: method, path: path, body: encoded, content_type: ctype)
        guard let url = URL(string: "\(origin)/api/edge/request") else {
            throw APIError.network("地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        if let t = token, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(envelope)

        let retryable = method.uppercased() == "GET" && body == nil
        let attempts = retryable ? 3 : 1
        var lastErr: Error = APIError.network("network error")
        for attempt in 0..<attempts {
            do {
                let (data, resp) = try await urlSession.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw APIError.network("bad response") }
                if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
                guard (200..<300).contains(http.statusCode) else {
                    let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
                    throw APIError.network("HTTP \(http.statusCode): \(snippet)")
                }
                if data.isEmpty { throw APIError.decoding("empty response") }
                // Envelope: {status, data?, msg?}
                let decoded = try JSONDecoder().decode(EdgeResponse<JSONValue>.self, from: data)
                guard decoded.status == 1 else {
                    throw APIError.server(decoded.msg ?? "接口返回失败")
                }
                guard let d = decoded.data?.raw else { throw APIError.decoding("missing data") }
                return try JSONDecoder().decode(T.self, from: d)
            } catch {
                lastErr = error
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: 350_000_000 * UInt64(attempt + 1))
                }
            }
        }
        throw lastErr
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await edge(method: "GET", path: path, token: session.token(for: base))
    }
    private func authed<T: Decodable>(method: String, path: String, body: [String: Any]? = nil) async throws -> T {
        guard let t = session.token(for: base) else { throw APIError.network("请先登录") }
        return try await edge(method: method, path: path, body: body, token: t)
    }

    // --- boot ---

    public struct Boot: Decodable {
        public var user: User?
        public var logged_in: Bool
        public var base: String
        public var strict_security: Bool?
    }
    public func boot() async {
        // app_boot is local in Rust; here it is just local session state.
        refreshUser()
        strictSecurity = true
    }

    public func setStrictSecurity(_ on: Bool) {
        strictSecurity = on
    }

    // --- auth ---

    public func login(username: String, password: String) async throws -> User {
        struct LoginData: Decodable { var token: String; var user: User? }
        let data: LoginData = try await edge(
            method: "POST", path: "/api/account/loginByPassword",
            body: ["username": username, "password": password])
        let origin = base
        session.set(origin: origin, token: data.token, user: data.user)
        refreshUser()
        return data.user ?? User(id: 0, username: username, nickname: username, avatar: "", avatar_color: "")
    }

    public func register(username: String, password: String, email: String = "") async throws -> User {
        struct RegData: Decodable { var token: String; var user: User? }
        var body: [String: Any] = ["username": username, "password": password, "confirm_password": password]
        if !email.isEmpty { body["email"] = email }
        let data: RegData = try await edge(method: "POST", path: "/api/account/registerByPassword", body: body)
        session.set(origin: base, token: data.token, user: data.user)
        refreshUser()
        return data.user ?? User(id: 0, username: username, nickname: username, avatar: "", avatar_color: "")
    }

    public func logout() async {
        if let t = session.token(for: base) {
            struct Empty: Decodable {}
            _ = try? await edge(method: "POST", path: "/api/account/logout", token: t) as Empty?
        }
        session.clear()
        refreshUser()
    }

    public func me() async throws -> User {
        let u: User = try await get("/api/account/me")
        if let t = session.token(for: base) {
            session.set(origin: base, token: t, user: u)
            refreshUser()
        }
        return u
    }

    // --- lists ---

    public func feed(page: Int = 1, size: Int = 20) async throws -> Paged<VideoCard> {
        try await get("/api/videos?page=\(page)&size=\(size)")
    }
    public func category(cate: String, page: Int = 1, size: Int = 20) async throws -> Paged<VideoCard> {
        try await get("/api/videos/category/\(cate)?page=\(page)&size=\(size)")
    }
    public func rank(kind: String) async throws -> RankResponse {
        let k = ["recommend", "potential"].contains(kind) ? kind : "hot"
        return try await get("/api/ranks/\(k)")
    }
    public func search(q: String, page: Int = 1, size: Int = 20) async throws -> SearchResponse {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return try await get("/api/search?q=\(enc)&page=\(page)&size=\(size)")
    }
    public func posts(page: Int = 1, size: Int = 20) async throws -> Paged<Post> {
        try await get("/api/posts?page=\(page)&size=\(size)")
    }
    public func post(id: Int) async throws -> PostDetail {
        try await get("/api/posts/\(id)")
    }

    // --- detail / play ---

    public func video(id: Int) async throws -> Detail {
        try await get("/api/videos/\(id)")
    }
    public func play(id: Int, ep: Int) async throws -> PlayInfo {
        try await get("/api/videos/\(id)/play?ep=\(ep)&page_texts=0")
    }

    // --- comments / interaction ---

    public func comments(id: Int, ep: Int, page: Int = 1, size: Int = 20) async throws -> CommentPage {
        try await get("/api/videos/\(id)/comments?ep=\(ep)&page=\(page)&size=\(size)")
    }
    public func commentSend(id: Int, ep: Int, text: String, replyId: Int? = nil) async throws {
        struct Empty: Decodable {}
        var body: [String: Any] = ["text": text]
        let path: String
        if let rid = replyId, rid > 0 {
            body["reply_id"] = rid
            path = "/api/videos/\(id)/comments"
        } else {
            path = "/api/videos/\(id)/comments?ep=\(ep)"
        }
        let _: Empty? = try await authed(method: "POST", path: path, body: body)
    }
    public func like(id: Int, ep: Int, on: Bool) async throws {
        struct Empty: Decodable {}
        let _: Empty? = try await authed(method: on ? "POST" : "DELETE", path: "/api/videos/\(id)/like?ep=\(ep)")
    }
    public func collect(id: Int, on: Bool) async throws {
        struct Empty: Decodable {}
        let _: Empty? = try await authed(method: on ? "POST" : "DELETE", path: "/api/videos/\(id)/collect")
    }
    public func follow(uid: Int, on: Bool) async throws {
        struct Empty: Decodable {}
        let _: Empty? = try await authed(method: on ? "POST" : "DELETE", path: "/api/users/\(uid)/follow")
    }
    public func postLike(id: Int, on: Bool) async throws {
        struct Empty: Decodable {}
        let _: Empty? = try await authed(method: on ? "POST" : "DELETE", path: "/api/posts/\(id)/like")
    }
    public func postCollect(id: Int, on: Bool) async throws {
        struct Empty: Decodable {}
        let _: Empty? = try await authed(method: on ? "POST" : "DELETE", path: "/api/posts/\(id)/collect")
    }
    public func postComments(id: Int, page: Int = 1, size: Int = 20) async throws -> CommentPage {
        try await get("/api/posts/\(id)/comments?page=\(page)&size=\(size)")
    }

    // --- lines ---

    public func lineState() -> LineState {
        LineState(base: base, default: HGLine.defaultBase,
                  fixed: HGLine.fixed.map { LineItem(name: $0.name, url: $0.url, host: nil) })
    }

    public func lineMirrors() async throws -> LineMirrors {
        guard let pageURL = URL(string: HGLine.publishPage) else {
            throw APIError.network("地址无效")
        }
        let (htmlData, _) = try await urlSession.data(from: pageURL)
        let html = String(decoding: htmlData, as: UTF8.self)
        let jsRel = Self.scriptSrc(html) ?? "publish.js"
        let jsURL = Self.absolute(base: HGLine.publishPage, rel: jsRel)
        guard let jsU = URL(string: jsURL) else { throw APIError.network("地址无效") }
        let (jsData, _) = try await urlSession.data(from: jsU)
        let js = String(decoding: jsData, as: UTF8.self)
        let domains = Self.jsArray(js, "var urls")
        let subs = Self.jsArray(js, "var subdomains")
        guard !domains.isEmpty else { throw APIError.network("地址发布页格式有变化：没找到镜像域名") }
        var items: [LineItem] = []
        var seen = Set<String>()
        outer: for domain in domains {
            let d = domain.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if d.isEmpty { continue }
            let hosts = subs.isEmpty ? [d] : subs.map { "\($0).\(d)" }
            for h in hosts {
                if seen.contains(h) { continue }
                seen.insert(h)
                items.append(LineItem(name: nil, url: "https://\(h)", host: h))
                if items.count >= HGLine.mirrorMax { break outer }
            }
        }
        guard !items.isEmpty else { throw APIError.network("地址发布页里没有可用的镜像地址") }
        return LineMirrors(source: HGLine.publishPage, script: jsURL, items: items)
    }

    public func lineProbe(urls: [String]) async -> [LineProbe] {
        // Concurrency groups of 6, mirrors lines.rs probe.
        var out: [LineProbe] = []
        for chunk in urls.chunked(into: 6) {
            await withTaskGroup(of: LineProbe.self) { group in
                for u in chunk {
                    group.addTask { await self.probeOne(u) }
                }
                for await r in group { out.append(r) }
            }
        }
        return out
    }

    private func probeOne(_ url: String) async -> LineProbe {
        let start = Date()
        guard let u = URL(string: url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/") else {
            return LineProbe(url: url, ok: false, status: nil, ms: 0, error: "invalid url")
        }
        do {
            let (_, resp) = try await urlSession.data(from: u)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return LineProbe(url: url, ok: code < 400, status: code,
                             ms: Int(Date().timeIntervalSince(start) * 1000), error: nil)
        } catch {
            return LineProbe(url: url, ok: false, status: nil,
                             ms: Int(Date().timeIntervalSince(start) * 1000),
                             error: error.localizedDescription)
        }
    }

    // --- update check (mirrors api.rs check_update) ---

    public struct UpdateInfo: Decodable {
        public var current: String
        public var latest: String
        public var tag: String?
        public var has_update: Bool
        public var url: String
        public var name: String?
        public var published_at: String?
        public var notes: String?
    }

    public func checkUpdate(current: String = "1.1.0") async throws -> UpdateInfo {
        guard let u = URL(string: "https://api.github.com/repos/Minireel/HGhub/releases/latest") else {
            throw APIError.network("地址无效")
        }
        let (data, resp) = try await urlSession.data(from: u)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            return UpdateInfo(current: current, latest: "", tag: nil, has_update: false,
                              url: "https://github.com/Minireel/HGhub/releases", name: nil, published_at: nil, notes: nil)
        }
        guard code == 200 else { throw APIError.network("GitHub 返回 HTTP \(code)") }
        struct GH: Decodable {
            var tag_name: String?; var html_url: String?; var body: String?
            var name: String?; var published_at: String?
        }
        let gh = try JSONDecoder().decode(GH.self, from: data)
        let tag = (gh.tag_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return UpdateInfo(
            current: current, latest: latest, tag: tag,
            has_update: !tag.isEmpty && Self.isNewer(tag, current),
            url: gh.html_url ?? "https://github.com/Minireel/HGhub/releases",
            name: gh.name, published_at: gh.published_at,
            notes: gh.body.map { String($0.prefix(800)) })
    }

    private static func verParts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "-", omittingEmptySubsequences: false) }
            .map { Int($0) ?? 0 }
    }
    static func isNewer(_ latest: String, _ current: String) -> Bool {
        let a = verParts(latest), b = verParts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // --- mirror-list parsing helpers (mirrors lines.rs) ---

    static func scriptSrc(_ html: String) -> String? {
        var rest = html[...]
        while let i = rest.range(of: "src=\"")?.upperBound {
            let after = rest[i...]
            guard let end = after.firstIndex(of: "\"") else { return nil }
            let cand = String(after[..<end])
            if cand.contains(".js") { return cand }
            rest = after[end...]
        }
        return nil
    }

    static func absolute(base: String, rel: String) -> String {
        if rel.hasPrefix("http://") || rel.hasPrefix("https://") { return rel }
        guard let b = URL(string: base), let host = b.host, let scheme = b.scheme else { return rel }
        let origin = "\(scheme)://\(host)"
        return rel.hasPrefix("/") ? origin + rel : origin + "/" + rel
    }

    static func jsArray(_ src: String, _ decl: String) -> [String] {
        guard let at = src.range(of: decl)?.lowerBound else { return [] }
        let rest = src[at...]
        guard let open = rest.firstIndex(of: "["),
              let close = rest[open...].firstIndex(of: "]") else { return [] }
        let body = String(rest[rest.index(after: open)..<close])
        return stripLineComments(body)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
            .filter { !$0.isEmpty }
    }

    static func stripLineComments(_ body: String) -> String {
        var out = ""; var quote: Character? = nil
        var it = body.makeIterator()
        while let c = it.next() {
            if let q = quote {
                out.append(c)
                if c == q { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c; out.append(c)
            } else if c == "/" {
                if let next = it.next(), next == "/" {
                    while let n = it.next() { if n == "\n" { out.append("\n"); break } }
                } else if let n = it.next() {
                    out.append(c); out.append(n)
                } else { out.append(c) }
            } else { out.append(c) }
        }
        return out
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
