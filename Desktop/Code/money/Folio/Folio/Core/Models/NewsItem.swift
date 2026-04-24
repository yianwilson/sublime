import Foundation

struct NewsItem: Identifiable {
    let id: String
    let title: String
    let publisher: String
    let publishedAt: Date
    let url: URL?
    let summary: String?
}
