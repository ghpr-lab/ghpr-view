import Foundation

struct ReviewThread: Identifiable, Codable {
    let id: String
    let isResolved: Bool
    let isOutdated: Bool
    let path: String?
    let line: Int?
    let comments: [ReviewComment]

    var latestComment: ReviewComment? {
        comments.last
    }

    var isUnresolved: Bool {
        !isResolved && !isOutdated
    }
}

struct ReviewComment: Identifiable, Codable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date
}
