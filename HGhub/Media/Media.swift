import CommonCrypto
import Foundation
import ImageIO
import UIKit

// MARK: - Constants (mirrors media.rs)

public enum HGMedia {
    public static let imgKey = Array("f5d965df75336270".utf8) // AES-128 key (ASCII)
    public static let imgIV  = Array("97b60394abc2fbe1".utf8) // AES-128-CBC IV (ASCII)
    static let imgCacheMax = 240
    static let plCacheMax = 60

    static let imgCache = NSCache<NSString, NSData>()
    static let plCache = NSCache<NSString, NSString>()
}

// MARK: - AES-128-CBC decryption + padding strip (mirrors aes_cbc_decrypt / strip_padding)

func aesCBCDecrypt(_ data: Data, key: [UInt8], iv: [UInt8]) -> Data? {
    guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
    var out = Data(count: data.count)
    var outLen = 0
    let outCount = out.count
    let status = data.withUnsafeBytes { dPtr in
        out.withUnsafeMutableBytes { oPtr in
            CCCrypt(
                UInt32(kCCDecrypt), UInt32(kCCAlgorithmAES128),
                CCOptions(0), key, kCCKeySizeAES128, iv,
                dPtr.baseAddress, data.count,
                oPtr.baseAddress, outCount, &outLen
            )
        }
    }
    guard status == kCCSuccess else { return nil }
    out.count = outLen
    return out
}

func stripPadding(_ buf: Data) -> Data {
    guard let pad = buf.last.map({ Int($0) }), pad > 0, pad <= 16, buf.count >= pad else { return buf }
    let tail = buf.suffix(pad)
    guard tail.allSatisfy({ Int($0) == pad }) else { return buf }
    return buf.dropLast(pad)
}

func imageKind(_ buf: Data) -> String? {
    guard buf.count >= 12 else { return nil }
    let b = [UInt8](buf.prefix(12))
    if b[0] == 0xFF && b[1] == 0xD8 { return "image/jpeg" }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if buf.starts(with: "GIF8".utf8) { return "image/gif" }
    if buf.starts(with: "RIFF".utf8) && b[8..<12] == ArraySlice(Array("WEBP".utf8)) { return "image/webp" }
    return nil
}

// MARK: - Image loading (mirrors load_image)

public actor CoverLoader {
    public static let shared = CoverLoader()

    private let session: URLSession
    private var cache: [String: (mime: String, data: Data)] = [:]

    init() {
        var c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.httpShouldSetCookies = false
        session = URLSession(configuration: c)
    }

    public func loadImage(url: String) async throws -> (mime: String, data: Data) {
        if let hit = cache[url] { return hit }
        guard let u = URL(string: url) else { throw APIError.network("地址无效") }
        var req = URLRequest(url: u)
        req.setValue("\(await API.shared.base)/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: req)
        let plain: Data
        if imageKind(data) != nil {
            plain = data
        } else {
            guard let dec = aesCBCDecrypt(data, key: HGMedia.imgKey, iv: HGMedia.imgIV) else {
                throw APIError.network("封面解密失败")
            }
            plain = stripPadding(dec)
        }
        let mime = imageKind(plain) ?? "image/jpeg"
        if cache.count >= HGMedia.imgCacheMax, let first = cache.keys.first { cache.removeValue(forKey: first) }
        cache[url] = (mime, plain)
        return (mime, plain)
    }

    public func loadUIImage(url: String) async throws -> UIImage {
        let (_, data) = try await loadImage(url: url)
        guard let img = UIImage(data: data) else { throw APIError.network("图片解码失败") }
        return img
    }

    public func clearCaches() {
        cache.removeAll()
        Task { @MainActor in HGMedia.imgCache.removeAllObjects(); HGMedia.plCache.removeAllObjects() }
    }
}

// MARK: - HLS playlist rewriting (mirrors rewrite_playlist / load_playlist)

// Mirrors media.rs: every URI attribute (KEY/MAP/MEDIA/SESSION-KEY/PART/etc.)
// is absolutized against the playlist base URL and rewritten to
// <prefix>/seg?u=<percent-encoded-absolute>. On iOS there is no local
// protocol, so the prefix is a local proxy server URL managed by HLSProxy.

func hlsAttributes(_ line: String) -> (tag: String, attrs: [String])? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let tag = String(line[..<colon])
    let rest = line[line.index(after: colon)...]
    var attrs: [String] = []
    var quoted = false
    var start = rest.startIndex
    for i in rest.indices {
        if rest[i] == "\"" { quoted.toggle() }
        if rest[i] == "," && !quoted {
            attrs.append(String(rest[start..<i]))
            start = rest.index(after: i)
        }
    }
    attrs.append(String(rest[start...]))
    return (tag, attrs)
}

func mapURIAttributes(_ line: String, _ rewrite: (String) -> String) -> String {
    guard let (tag, attrs) = hlsAttributes(line) else { return line }
    let mapped = attrs.map { attr -> String in
        if let eq = attr.firstIndex(of: "=") {
            let key = String(attr[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(attr[attr.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "URI", value.hasPrefix("\""), value.hasSuffix("\"") {
                let uri = String(value.dropFirst().dropLast())
                return "\(key)=\"\(rewrite(uri))\""
            }
        }
        return attr
    }
    return "\(tag):\(mapped.joined(separator: ","))"
}

func absolutize(base: String, target: String) -> String {
    if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
    if let b = URL(string: base), let j = URL(string: target, relativeTo: b)?.absoluteURL.absoluteString {
        return j
    }
    return target
}

public func rewritePlaylist(baseURL: String, text: String, prefix: String) -> String {
    var out = ""
    let trimmed = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
    for raw in trimmed.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.isEmpty { out += "\n"; continue }
        if line.hasPrefix("#") {
            if line.hasPrefix("#EXT-X-CONTENT-STEERING:") { continue }
            if line.hasPrefix("#EXT-X-DATERANGE:") {
                if let (tag, attrs) = hlsAttributes(line) {
                    let safe = attrs.filter { attr in
                        let key = (attr.split(separator: "=").first.map(String.init) ?? "")
                            .trimmingCharacters(in: .whitespaces).uppercased()
                        return !key.contains("URI") && key != "X-ASSET-LIST"
                    }
                    out += "\(tag):\(safe.joined(separator: ","))\n"
                }
                continue
            }
            if line.contains("URI=\"") {
                let abs = mapURIAttributes(line) { absolutize(base: baseURL, target: $0) }
                let rewritten = mapURIAttributes(abs) { "\(prefix)/seg?u=\(percentEncode($0))" }
                out += rewritten + "\n"
            } else {
                out += line + "\n"
            }
        } else {
            let abs = absolutize(base: baseURL, target: line)
            out += "\(prefix)/seg?u=\(percentEncode(abs))\n"
        }
    }
    return out
}

func percentEncode(_ s: String) -> String {
    // Mirrors Rust utf8_percent_encode(NON_ALPHANUMERIC): encode everything except alphanumerics.
    s.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics) ?? s
}

// MARK: - Media URL helpers (mirrors api.ts mediaUrl / playlist / directMedia)

public enum HGAUrl {
    public static func playlist(_ url: String, proxy: HLSProxy) -> String {
        "\(proxy.base)/hls?u=\(percentEncode(url))"
    }
    public static func directMedia(_ url: String, proxy: HLSProxy) -> String {
        "\(proxy.base)/seg?u=\(percentEncode(url))"
    }
    public static func mediaURL(_ url: String, proxy: HLSProxy) -> String {
        // m3u8 → playlist rewrite; otherwise direct passthrough.
        let clean = url.split(separator: "?").first.map(String.init) ?? url
        return clean.lowercased().hasSuffix(".m3u8") ? playlist(url, proxy: proxy) : directMedia(url, proxy: proxy)
    }
}
