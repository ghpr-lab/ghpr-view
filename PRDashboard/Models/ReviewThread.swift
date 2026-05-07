import Foundation

struct ReviewThread: Identifiable, Codable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String?
    let line: Int?
    let comments: [ReviewComment]
    // Overlay applied by PRManager from its persisted Set<String>; not encoded.
    var isRead: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, isResolved, isOutdated, path, line, comments
    }

    var latestComment: ReviewComment? {
        comments.last
    }

    var isUnresolved: Bool {
        !isResolved && !isOutdated
    }

    var isUnreadUnresolved: Bool {
        isUnresolved && !isRead
    }

    var isReadUnresolved: Bool {
        isUnresolved && isRead
    }
}

struct ReviewComment: Identifiable, Codable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date
}
