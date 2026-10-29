import Foundation

/// Settings for real-time alerts, fired by AlertingService the moment a
/// device that's actively recording or mid-workflow drops offline, loses
/// auth, runs out of media, or is about to run out of storage — the
/// failures that matter most because they can silently kill a live
/// recording while no one's watching the dashboard.
struct AlertSettings: Codable {
    var isEnabled: Bool = true

    /// Always shown as a macOS notification. Also emailed to these
    /// recipients if the list isn't empty and the church site is connected.
    var emailRecipients: [NotificationRecipient] = []

    /// Warn once a recording deck's used capacity crosses this percentage
    /// of its configured total. Only applies to decks with a capacity
    /// entered in their device settings — others can't be checked.
    var lowStorageThresholdPercent: Int = 90

    /// After a restart, pick up interrupted runs whose remaining steps are safe to repeat (never Format, Cleanup or
    /// Control HyperDeck). Off by default.
    var autoResumeInterrupted: Bool = false

    /// A morning email to `emailRecipients` summarising the last day's runs and any devices that are down.
    var dailySummary: Bool = false

    init() {}

    /// Settings saved before the newer options existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        emailRecipients = try c.decodeIfPresent([NotificationRecipient].self, forKey: .emailRecipients) ?? []
        lowStorageThresholdPercent = try c.decodeIfPresent(Int.self, forKey: .lowStorageThresholdPercent) ?? 90
        autoResumeInterrupted = try c.decodeIfPresent(Bool.self, forKey: .autoResumeInterrupted) ?? false
        dailySummary = try c.decodeIfPresent(Bool.self, forKey: .dailySummary) ?? false
    }
}
