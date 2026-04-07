import Foundation

struct UpcomingEvent: Identifiable {
    enum Kind {
        case earnings(isOwned: Bool)
        case fedDecision
    }

    let id: String
    let date: Date
    let symbol: String?   // nil for macro events
    let name: String
    let kind: Kind

    var daysUntil: Int {
        Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    var relativeLabel: String {
        switch daysUntil {
        case 0:  return "Today"
        case 1:  return "Tomorrow"
        default: return "In \(daysUntil)d"
        }
    }
}
