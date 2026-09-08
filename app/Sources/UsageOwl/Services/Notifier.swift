import Foundation
import UserNotifications

/// Fires local notifications when a quota window crosses 25/50/75/90%.
/// Each threshold fires once per window; tracking re-arms when the window resets.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private let queue = DispatchQueue(label: "app.usageowl.notifier")
    private var fired: [String: Set<Int>] = [:]
    private var resetMarkers: [String: Date] = [:]
    private var monthMarkers: [String: String] = [:]

    /// Prevents an older asynchronous pending-request lookup from winning
    /// after a newer refresh/preferences change has already been requested.
    private var resetScheduleGeneration: [String: Int] = [:]

    /// Spend alerts start at 50%: crossing a quarter of a monthly money cap is
    /// routine, and this is the one alert that shouldn't cry wolf.
    private static let spendThresholds = [50, 75, 90]

    /// UserNotifications requires a real app bundle; skip when run as a bare binary.
    private var bundled: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(snapshot: UsageSnapshot) {
        guard bundled, snapshot.error == nil else { return }
        queue.async {
            for window in snapshot.windows {
                let key = "\(snapshot.id).\(window.label)"
                if let reset = window.resetDate {
                    if let marker = self.resetMarkers[key], abs(marker.timeIntervalSince(reset)) > 1 {
                        self.fired[key] = []  // new period — re-arm alerts
                    }
                    self.resetMarkers[key] = reset
                }
                for threshold in [25, 50, 75, 90] where window.usedPercent >= Double(threshold) {
                    guard self.fired[key, default: []].contains(threshold) == false else { continue }
                    self.fired[key, default: []].insert(threshold)
                    self.deliver(snapshot: snapshot, window: window, threshold: threshold)
                }
            }
            self.checkSpend(snapshot)
        }
    }

    /// Extra-usage credits are real money against a monthly cap, so they get the
    /// same treatment as a quota window.
    private func checkSpend(_ snapshot: UsageSnapshot) {
        guard let spend = snapshot.spend, let percent = spend.chargePercent else { return }
        let key = "\(snapshot.id).extra-usage"
        // Re-arm monthly: the cap resets with the billing month and the API
        // reports no reset timestamp for it, so there's no date to compare.
        let month = Self.monthMarker()
        if monthMarkers[key] != month {
            fired[key] = []
            monthMarkers[key] = month
        }
        for threshold in Self.spendThresholds where percent >= Double(threshold) {
            guard fired[key, default: []].contains(threshold) == false else { continue }
            fired[key, default: []].insert(threshold)
            deliverSpend(snapshot: snapshot, spend: spend, percent: percent, threshold: threshold)
        }
    }

    private static func monthMarker() -> String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private func deliverSpend(snapshot: UsageSnapshot, spend: SpendSummary,
                              percent: Double, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(snapshot.displayName): \(threshold)% of extra-usage credits used"
        var body = Format.usd(spend.chargedUSD ?? 0, cents: true)
        if let limit = spend.chargeLimitUSD {
            body += " of \(Format.usd(limit, cents: true))"
        }
        body += " charged this month · \(Format.percent(percent))"
        content.body = body
        content.sound = .default
        let id = "\(snapshot.id).extra-usage.\(Self.monthMarker()).\(threshold)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func deliver(snapshot: UsageSnapshot, window: UsageWindow, threshold: Int) {
        let content = UNMutableNotificationContent()
        content.title = "\(snapshot.displayName): \(threshold)% of \(window.label) quota used"
        var body = "Currently at \(Format.percent(window.usedPercent))"
        if let countdown = Format.countdown(to: window.resetDate) { body += " · \(countdown)" }
        content.body = body
        content.sound = .default
        let id = "\(snapshot.id).\(window.label).\(threshold)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - Reset notifications

    /// Reconciles native macOS notifications for every reset timestamp reported
    /// by one provider. Stable request identifiers mean a changed reset time
    /// replaces the old pending request instead of creating duplicates.
    func syncResetNotifications(
        snapshot: UsageSnapshot,
        warningEnabled: Bool,
        completionEnabled: Bool
    ) {
        guard bundled, snapshot.error == nil else { return }

        queue.async {
            let providerID = snapshot.id
            let generation =
                (self.resetScheduleGeneration[providerID] ?? 0) + 1

            self.resetScheduleGeneration[providerID] = generation

            let requests = Self.makeResetRequests(
                snapshot: snapshot,
                warningEnabled: warningEnabled,
                completionEnabled: completionEnabled
            )

            let desiredIDs = Set(requests.map(\.identifier))
            let prefix = Self.resetPrefix(providerID: providerID)
            let center = UNUserNotificationCenter.current()

            center.getPendingNotificationRequests { pending in
                self.queue.async {
                    guard self.resetScheduleGeneration[providerID] == generation else {
                        return
                    }

                    // Remove only obsolete reset requests belonging to this
                    // provider. Threshold/spend alerts are deliberately left alone.
                    let staleIDs = pending
                        .map(\.identifier)
                        .filter {
                            $0.hasPrefix(prefix) &&
                            !desiredIDs.contains($0)
                        }

                    if !staleIDs.isEmpty {
                        center.removePendingNotificationRequests(
                            withIdentifiers: staleIDs
                        )
                    }

                    // Adding the same identifier replaces its previous pending
                    // request, which also handles provider reset-time changes.
                    for request in requests {
                        center.add(request)
                    }
                }
            }
        }
    }

    /// Quick manual verification from Settings so we do not have to wait for
    /// a real five-hour/weekly reset to prove macOS delivery works.
    func sendTestResetNotification() {
        guard bundled else { return }

        let content = UNMutableNotificationContent()
        content.title = "UsageOwl reset notifications are working"
        content.body = "This is a native macOS test notification."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 3,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: "usageowl.reset.test",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    private static func makeResetRequests(
        snapshot: UsageSnapshot,
        warningEnabled: Bool,
        completionEnabled: Bool
    ) -> [UNNotificationRequest] {
        let now = Date()
        var requests: [UNNotificationRequest] = []

        for window in snapshot.windows {
            guard
                let reset = window.resetDate,
                reset.timeIntervalSince(now) > 1
            else {
                continue
            }

            // The provider and window label form a stable identity. We do NOT
            // include the reset timestamp, because the same request should be
            // replaced when a provider revises that timestamp.
            let baseID =
                "\(resetPrefix(providerID: snapshot.id))\(window.label)"

            if warningEnabled {
                let warningDate = reset.addingTimeInterval(-10 * 60)

                if warningDate.timeIntervalSince(now) > 1 {
                    let content = UNMutableNotificationContent()
                    content.title =
                        "\(snapshot.displayName): \(Format.displayLabel(window.label)) resets in 10 minutes"

                    var body =
                        "Current usage: \(Format.percent(window.usedPercent))"

                    if let resetText = Format.resetText(reset) {
                        body += " · \(resetText)"
                    }

                    content.body = body
                    content.sound = .default

                    if let request = scheduledRequest(
                        identifier: baseID + ".warning",
                        content: content,
                        fireDate: warningDate
                    ) {
                        requests.append(request)
                    }
                }
            }

            if completionEnabled {
                let content = UNMutableNotificationContent()
                content.title =
                    "\(snapshot.displayName): \(Format.displayLabel(window.label)) reset"

                content.body =
                    "Your \(Format.displayLabel(window.label)) usage window has reset."

                content.sound = .default

                if let request = scheduledRequest(
                    identifier: baseID + ".reset",
                    content: content,
                    fireDate: reset
                ) {
                    requests.append(request)
                }
            }
        }

        return requests
    }

    private static func scheduledRequest(
        identifier: String,
        content: UNMutableNotificationContent,
        fireDate: Date
    ) -> UNNotificationRequest? {
        let delay = fireDate.timeIntervalSinceNow
        guard delay > 1 else { return nil }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: delay,
            repeats: false
        )

        return UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
    }

    private static func resetPrefix(providerID: String) -> String {
        "usageowl.reset.\(providerID)."
    }

    /// Show banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
