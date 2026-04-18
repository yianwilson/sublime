import Foundation
import UserNotifications

@MainActor
final class AlertsService {

    static let shared = AlertsService()
    private init() {}

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Check all active alerts against latest quotes. Fires a local notification
    /// for each alert that has been triggered, then deactivates it.
    /// Returns the updated alert list (some may be deactivated).
    func checkAlerts(_ alerts: [PriceAlert], quotes: [String: AssetQuote]) -> [PriceAlert] {
        var updated = alerts
        for i in updated.indices {
            let alert = updated[i]
            guard alert.isActive, let quote = quotes[alert.symbol] else { continue }
            let triggered: Bool
            switch alert.direction {
            case .above: triggered = quote.currentPrice >= alert.targetPrice
            case .below: triggered = quote.currentPrice <= alert.targetPrice
            }
            if triggered {
                updated[i].isActive = false
                fireNotification(for: alert, currentPrice: quote.currentPrice)
            }
        }
        return updated
    }

    private func fireNotification(for alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.symbol) Price Alert"
        let directionStr = alert.direction == .above ? "above" : "below"
        content.body = "\(alert.symbol) is now \(String(format: "%.2f", currentPrice)), which is \(directionStr) your target of \(String(format: "%.2f", alert.targetPrice))."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: alert.id.uuidString,
            content: content,
            trigger: nil  // immediate delivery
        )
        UNUserNotificationCenter.current().add(request)
    }
}
