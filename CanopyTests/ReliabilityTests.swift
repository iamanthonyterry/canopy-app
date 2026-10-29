import Foundation
import Testing
@testable import Canopy

@MainActor
struct ReliabilityTests {
    @Test func emptyAllowListAcceptsAnyone() {
        #expect(OSCAccess.allows(host: "10.0.0.9", allowList: ""))
    }

    @Test func allowListMatchesAddressesAndPrefixes() {
        let list = "192.168.1.20, 10.0.5.\nlocalhost"
        #expect(OSCAccess.allows(host: "192.168.1.20", allowList: list))
        #expect(!OSCAccess.allows(host: "192.168.1.200", allowList: list), "a full address matches exactly")
        #expect(OSCAccess.allows(host: "10.0.5.77", allowList: list))
        #expect(OSCAccess.allows(host: "127.0.0.1", allowList: list))
        #expect(OSCAccess.allows(host: "::ffff:192.168.1.20%en0", allowList: list), "IPv4-mapped and zoned forms")
        #expect(!OSCAccess.allows(host: "172.16.0.4", allowList: list))
    }

    @Test func attentionMessagePrefersInterruptedThenUnacknowledgedErrors() {
        let ok = WorkflowRun(workflowName: "A", startedAt: .now, finishedAt: .now, processed: 3, errors: 0, decksProcessed: [], log: [])
        let bad = WorkflowRun(workflowName: "Sunday", startedAt: .now, finishedAt: .now, processed: 3, errors: 2, decksProcessed: [], log: [])
        #expect(AutomationAttention.message(interrupted: 1, lastRun: ok, acknowledged: nil) == "An automation was interrupted")
        #expect(AutomationAttention.message(interrupted: 0, lastRun: ok, acknowledged: nil) == nil)
        #expect(AutomationAttention.message(interrupted: 0, lastRun: bad, acknowledged: nil) == "“Sunday” finished with 2 errors")
        #expect(AutomationAttention.message(interrupted: 0, lastRun: bad, acknowledged: bad.id) == nil)
    }

    @Test func dailySummaryIsDueOncePerDayAfterSeven() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ d: Int, _ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h))! }
        #expect(!HealthSummaryService.isDue(now: at(28, 6), lastSent: nil, calendar: cal))
        #expect(HealthSummaryService.isDue(now: at(28, 7), lastSent: nil, calendar: cal))
        #expect(!HealthSummaryService.isDue(now: at(28, 12), lastSent: at(28, 7), calendar: cal))
        #expect(HealthSummaryService.isDue(now: at(29, 8), lastSent: at(28, 7), calendar: cal))
    }

    @Test func oldAlertSettingsStillLoad() throws {
        let old = Data(#"{"isEnabled":false,"emailRecipients":[],"lowStorageThresholdPercent":80}"#.utf8)
        let s = try JSONDecoder().decode(AlertSettings.self, from: old)
        #expect(!s.isEnabled && s.lowStorageThresholdPercent == 80 && !s.autoResumeInterrupted && !s.dailySummary)
    }
}
