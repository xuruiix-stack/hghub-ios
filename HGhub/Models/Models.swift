import Foundation

// MARK: - Core models (mirrors src/types.ts)

public struct Author: Decodable {
    public var id: Int
    public var name: String
    public var avatar: String?
    public var followers: Int?
}

public struct Paged<T: Decodable>: Decodable {
    public var items: [T]
    public var pagination: Pagination
}

public struct Pagination: Decodable {
    public var page: Int
    public var pages: Int
    public var size: Int
    public var total: Int
}

public struct VideoCard: Decodable, Identifiable {
    public var id: Int
    public var title: String
    public var cover: String
    public var description: String?
    public var tags: [String]
    public var score: Double
    public var episode_count: Int
    public var total_episodes: Int
    public var duration: String?
    public var hot: Int
    public var like_count: Int
    public var collect_count: Int
    public var comment_count: Int
    public var is_finished: Bool
    public var is_original: Int
    public var created_at: String?
    public var last_ep_at: Int?
    public var new_at: Int?
    public var author: Author?
}

public struct Episode: Decodable {
    public var ep_num: Int
    public var title: String
    public var duration: Double
    public var status: Int
}

public struct Detail: Decodable {
    public var id: Int
    public var title: String
    public var description: String
    public var cover: String
    public var tags: [String]
    public var tag_links: [TagLink]?
    public var score: Double
    public var episode_count: Int
    public var total_episodes: Int
    public var episodes: [Episode]
    public var counts: DetailCounts
    public var author: DetailAuthor
    public var interaction: Interaction?
    public var video_url: String?
    public var video_url_hevc: String?
    public var is_finished: Bool
    public var is_original: Int
    public var video_type: Int?
    public var duration: Double?
    public var created_at: String?
}

public struct TagLink: Decodable {
    public var name: String
    public var url: String
}

public struct DetailCounts: Decodable {
    public var collect: Int
    public var comment: Int
    public var hot: Int
    public var like: Int
}

public struct DetailAuthor: Decodable {
    public var id: Int
    public var name: String
    public var avatar: String?
    public var followers: Int?
    public var is_following: Bool?
    public var following: Int?
    public var like_count: Int?
}

public struct Interaction: Decodable {
    public var collected: Bool
    public var liked: Bool
    public var liked_ep: Int?
}

public struct PlayInfo: Decodable {
    public var id: Int
    public var ep_num: Int
    public var duration: Double
    public var title: String
    public var video_url: String
    public var video_url_hevc: String?
}

public struct RankItem: Decodable, Identifiable {
    public var id: Int? { video_id }
    public var rank: Int
    public var video_id: Int
    public var title: String
    public var cover: String
    public var tags: [String]
    public var score: Double
    public var cate_name: String
    public var episode_count: Int
    public var is_finished: Bool
    public var metric_label: String
    public var metric_value: Double
    public var metrics: RankMetrics
}

public struct RankMetrics: Decodable {
    public var collect: Int
    public var comment: Int
    public var like: Int
    public var play: Int
}

public struct RankResponse: Decodable {
    public var type: String?
    public var items: [RankItem]
}

public struct SearchResponse: Decodable {
    public var items: [VideoCard]
    public var pagination: Pagination
    public var keyword: String?
}

public struct Comment: Decodable, Identifiable {
    public var id: Int
    public var user_id: Int
    public var nickname: String
    public var avatar: String
    public var avatar_color: String
    public var text: String
    public var time: String
    public var created_at: String?
    public var like_count: Int
    public var liked: Bool
    public var reply_count: Int
    public var reply_id: Int
    public var reply_list: [Comment]?
    public var is_pinned: Bool?
    public var ip_region: String?
}

public struct CommentPage: Decodable {
    public var ep: Int
    public var revision: String?
    public var reset: Bool?
    public var items: [Comment]
    public var pagination: Pagination
}

public struct Post: Decodable, Identifiable {
    public var id: Int
    public var title: String
    public var desc: String?
    public var content: String?
    public var cover: String
    public var tags: [String]
    public var hot: Int
    public var video_url: String?
    public var video_id: Int?
    public var author: PostAuthor?
    public var counts: PostCounts?
    public var created_at: String?
    public var publish_time: String?
}

public struct PostAuthor: Decodable {
    public var id: Int
    public var name: String
    public var avatar: String?
    public var is_following: Bool?
}

public struct PostCounts: Decodable {
    public var like: Int?
    public var comment: Int?
    public var collect: Int?
    public var share: Int?
    public var hot: Int?
}

public struct PostDetail: Decodable {
    public var id: Int
    public var title: String
    public var desc: String?
    public var content: String?
    public var cover: String
    public var tags: [String]
    public var hot: Int
    public var video_url: String?
    public var video_id: Int?
    public var author: PostAuthor?
    public var counts: PostCounts?
    public var created_at: String?
    public var publish_time: String?
}

public struct User: Codable {
    public var id: Int
    public var username: String
    public var nickname: String
    public var avatar: String
    public var avatar_color: String
    public var sign: String?
    public var desc: String?
    public var user_type: String?
    public var counts: [String: Int]?
    public var interactions: UserInteractions?
}

public struct UserInteractions: Codable {
    public var like_video_ids: [Int]?
    public var favorite_video_ids: [Int]?
    public var follow_user_ids: [Int]?
    public var like_video_episodes: [VideoEpisode]?
}

public struct VideoEpisode: Codable {
    public var video_id: Int
    public var ep: Int
}

// MARK: - Formatting helpers (mirrors api.ts fmt/fmtTime/dur)

public func fmt(_ n: Int?) -> String {
    let v = Double(n ?? 0)
    if v >= 100_000_000 { return "\(String(format: "%.1f", v/100_000_000).replacingOccurrences(of: ".0", with: ""))亿" }
    if v >= 10_000 { return "\(String(format: "%.1f", v/10_000).replacingOccurrences(of: ".0", with: ""))万" }
    return "\(n ?? 0)"
}

public func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    return "\(Int(s)/60):\(String(format: "%02d", Int(s)%60))"
}

public func dur(_ s: Double?) -> String {
    guard let n = s, n > 0 else { return "" }
    return "\(Int(n)/60):\(String(format: "%02d", Int(n)%60))"
}
