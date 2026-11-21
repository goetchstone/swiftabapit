import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

/// "Needs attention" (plan §8.0): every rule is judged only over a complete read, and says so; anything less is skipped, in
/// words, and never reads as "nothing found" (invariant 8). Each rule is its report's rule: the tests hold it to the report.
@Suite("Needs attention")
struct NeedsAttentionTests {
    typealias Input = NeedsAttention.Input
    typealias Rule = NeedsAttention.Rule

    static let thresholds = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 14, quietServiceDays: 30)
    static let day: TimeInterval = 86_400
    static let recent = JSONValue.string(Fleet.stamp(-day))

    // MARK: builders

    static func whole<E>(_ items: [E], takenAt: Date? = nil) -> NeedsAttention.Listed<E> { .init(items, read: .whole, takenAt: takenAt) }

    static func service(_ id: String, type: String? = "MDM", status: String? = "ACTIVE", last: JSONValue? = recent) -> MDMService {
        var attributes: JSONObject = ["serverName": .string("Service \(id)")]
        if let type { attributes = attributes.merging(["serverType": .string(type)]) }
        if let status { attributes = attributes.merging(["status": .string(status)]) }
        if let last { attributes = attributes.merging(["lastConnectedDateTime": last]) }
        return MDMService(resource: Resource(type: "mdmServers", id: id, attributes: attributes))
    }

    static func mdm(_ id: String, serial: String?, family: String? = "Mac") -> MDMDevice {
        var attributes: JSONObject = [:]
        if let serial { attributes = attributes.merging(["serialNumber": .string(serial)]) }
        if let family { attributes = attributes.merging(["productFamily": .string(family)]) }
        return MDMDevice(resource: Resource(type: "mdmDevices", id: id, attributes: attributes))
    }

    static func detail(_ attributes: JSONObject) -> MDMDeviceDetail {
        MDMDeviceDetail(resource: Resource(type: "mdmDeviceDetails", id: "d", attributes: attributes))
    }

    /// A Mosyle device as the adapter makes it: listed by its serial, which is also its `serialNumber`.
    static func mosyle(_ serial: String, checkIn: JSONValue? = recent) -> Resource {
        var attributes: JSONObject = ["serialNumber": .string(serial)]
        if let checkIn { attributes = attributes.merging(["lastCheckIn": checkIn]) }
        return Resource(type: "devices", id: serial, attributes: attributes)
    }

    /// A Mosyle device with no serial: the adapter lists it by its UDID, or by nothing (an empty id) when it has neither.
    static func mosyleWithoutSerial(_ udid: String) -> Resource {
        Resource(type: "devices", id: udid, attributes: udid.isEmpty ? [:] : ["deviceUdid": .string(udid)])
    }

    /// Every list read whole and empty, the client's Mosyle org set to an ordinary service (recently connected), its devices
    /// read whole and empty: every rule is judged and finds nothing.
    static func base() -> Input {
        var input = Input()
        input.devices = whole([])
        input.services = whole([service("svc-mosyle")])
        input.serviceDevices = ["svc-mosyle": whole([])]
        input.appleMDM = whole([])
        input.mosyle = .devices(whole([]))
        input.mosyleServiceID = "svc-mosyle"
        return input
    }

    static func run(_ input: Input, _ thresholds: NeedsAttention.Thresholds = thresholds, now: Date = Fleet.now) -> NeedsAttention {
        NeedsAttention(input, thresholds: thresholds, now: now)
    }

    static func subjects(_ input: Input, _ rule: Rule, _ thresholds: NeedsAttention.Thresholds = thresholds) -> [String] {
        run(input, thresholds).result(rule).findings.map(\.subject)
    }

    static func skip(_ input: Input, _ rule: Rule) -> String? {
        if case .skipped(let why) = run(input).result(rule).verdict { return why }
        return nil
    }

    /// A skipped rule hands the store nothing, finds nothing and says no count.
    static func expectSkipped(_ result: NeedsAttention.RuleResult, containing text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .skipped(let why) = result.verdict else {
            Issue.record("\(result.rule) was judged, expected skipped: \(text)", sourceLocation: sourceLocation)
            return
        }
        #expect(why.contains(text), "\(why)", sourceLocation: sourceLocation)
        #expect(result.findings.isEmpty && result.subjectsToRecord == nil, sourceLocation: sourceLocation)
        #expect(result.words.count == 1 && result.words[0].contains("skipped") && !result.words[0].contains("found"), sourceLocation: sourceLocation)
    }

    /// A partial rule shows what it found, says on its own line why it is partial (how much wasn't read, or which devices
    /// couldn't be matched), marks every finding partial, and hands the store nothing (the operator, 2026-11-20: "Show what it
    /// found, marked partial").
    static func expectPartial(_ result: NeedsAttention.RuleResult, containing text: String, found: [String],
                              sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .partial(let why) = result.verdict else {
            Issue.record("\(result.rule) is \(result.verdict), expected partial: \(text)", sourceLocation: sourceLocation)
            return
        }
        #expect(why.contains(text), "\(why)", sourceLocation: sourceLocation)
        #expect(result.findings.map(\.subject) == found, sourceLocation: sourceLocation)
        #expect(result.findings.allSatisfy(\.isPartial) && !result.isJudged, sourceLocation: sourceLocation)
        #expect(result.subjectsToRecord == nil, sourceLocation: sourceLocation)
        #expect(result.words.first?.hasSuffix("marked partial.") == true && result.words.dropFirst().first == "\(why)."
                && result.words.contains { $0.contains("isn't kept for later") }, sourceLocation: sourceLocation)
    }

    // MARK: every rule

    @Test func ruleIDsAreIdentifiersTheStoreKeeps() {
        #expect(Set(Rule.allCases.map(\.rawValue)).count == Rule.allCases.count)
        for rule in Rule.allCases { #expect(NeedsAttention.isIdentifier(rule.rawValue, limit: NeedsAttention.ruleLimit), "\(rule)") }
        #expect(Rule.allCases.filter(\.needsMosyle) == [.missingFromMosyle, .mosyleNotInApple, .mosyleCheckIn])
    }

    /// Nothing handed to the rules: every rule is skipped and says why, none says "none found", and the store is told nothing.
    @Test func nothingReadSkipsEveryRuleAndSaysWhy() {
        let report = Self.run(Input())
        #expect(report.results.map(\.rule) == Rule.allCases)
        for result in report.results {
            #expect(!result.isJudged, "\(result.rule)")
            #expect(result.subjectsToRecord == nil, "\(result.rule)")
            #expect(result.words.allSatisfy { !$0.contains("none found") }, "\(result.rule)")
        }
        #expect(report.findings.isEmpty)
        Self.expectSkipped(report.result(.activationLock), containing: "Apple's device list wasn't read (not read yet)")
    }

    /// Every list read whole and empty: every rule is judged, finds nothing, and hands the store `[]` (not nil).
    @Test func everythingReadWholeJudgesEveryRule() {
        let report = Self.run(Self.base())
        for result in report.results {
            #expect(result.verdict == .judged, "\(result.rule): \(result.verdict)")
            #expect(result.subjectsToRecord == [], "\(result.rule)")
            #expect(result.words.first?.hasSuffix("none found.") == true, "\(result.rule)")
            #expect(result.takenAt == nil)
        }
    }

    @Test func aClientWithNoMosyleOrgSkipsEveryMosyleRuleAndSaysSo() {
        var input = Self.base()
        input.mosyle = .noMosyleOrg
        let report = Self.run(input)
        for rule in Rule.allCases {
            if rule.needsMosyle {
                Self.expectSkipped(report.result(rule), containing: "no Mosyle Business org")
            } else {
                #expect(report.result(rule).isJudged, "\(rule)")
            }
        }
        // A Mosyle org whose list wasn't read is not "no Mosyle org": it says the read.
        input.mosyle = .devices(.notRead("Mosyle refused the token"))
        Self.expectSkipped(Self.run(input).result(.mosyleNotInApple), containing: "Mosyle's device list wasn't read (Mosyle refused the token)")
    }

    @Test func titlesSayTheThresholds() {
        let t = NeedsAttention.Thresholds(checkInDays: 7, appleCareExpiringDays: 1, migrationDeadlineDays: 3, quietServiceDays: 45)
        #expect(Rule.mosyleCheckIn.title(t).contains("7 days"))
        #expect(Rule.appleCareExpiring.title(t).contains("within 1 day"))
        #expect(Rule.migrationDeadline.title(t).contains("3 days"))
        #expect(Rule.quietService.title(t).contains("45 days"))
    }

    // MARK: 1. assigned in Apple to an MDM, missing from it

    static func appleMDMInput() -> Input {
        var input = base()
        input.services = whole([service("svc-mosyle"), service("svc-apple", type: "APPLE_MDM"), service("svc-other")])
        input.serviceDevices = ["svc-mosyle": whole([]), "svc-apple": whole(["S1", "S2", "S3"]), "svc-other": whole(["S4"])]
        input.appleMDM = whole([mdm("m1", serial: "S1"), mdm("m3", serial: "S3")])
        input.devices = whole(["S1", "S2", "S3", "S4"].map { Fleet.device($0) })
        return input
    }

    @Test func assignedToAppleMDMButNotEnrolledIsFound() {
        let input = Self.appleMDMInput()
        let result = Self.run(input).result(.missingFromAppleMDM)
        #expect(result.findings.map(\.subject) == ["S2"])
        #expect(result.findings[0].reason == "Assigned in Apple to Service svc-apple; Apple MDM doesn't list it.")
        #expect(result.subjectsToRecord == ["S2"])
        var all = input
        all.appleMDM = Self.whole([Self.mdm("m1", serial: "S1"), Self.mdm("m2", serial: "S2"), Self.mdm("m3", serial: "S3")])
        #expect(Self.run(all).result(.missingFromAppleMDM).findings.isEmpty && Self.run(all).result(.missingFromAppleMDM).isJudged)
    }

    /// No Apple MDM service: nothing can be assigned to it. Judged over the whole services list, even with Apple MDM unread.
    @Test func noAppleMDMServiceIsJudgedWithNothingAssigned() {
        var input = Self.base()
        input.appleMDM = .notRead("Apple School Manager has no Apple MDM")
        let result = Self.run(input).result(.missingFromAppleMDM)
        #expect(result.isJudged && result.findings.isEmpty)
    }

    /// The side assigned in Apple read in part: what was read is looked for, marked partial. The side searched (Apple MDM's
    /// list) read in part: an absence can't be judged, so the rule is skipped and names that list.
    @Test func missingFromAppleMDMIsPartialOverAPartAssignedSideAndSkippedOverAPartMDMList() {
        var input = Self.appleMDMInput()
        input.services.read = .partly("showing 100 of at least 120")
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM), containing: "read in part (showing 100 of at least 120)", found: ["S2"])

        input = Self.appleMDMInput()
        input.services.notSent = ["serverType"]
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "didn't send the services' type")

        input = Self.appleMDMInput()
        input.services.items.append(Self.service("svc-untyped", type: nil))
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM), containing: "1 of 4 services came with no type", found: ["S2"])

        // The only Apple MDM service's devices not read: nothing to look for.
        input = Self.appleMDMInput()
        input.serviceDevices["svc-apple"] = nil
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "The device list of Service svc-apple wasn't read")
        input.serviceDevices["svc-apple"] = .notRead("your role can't read this")
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "wasn't read (your role can't read this)")

        // One of two Apple MDM services read: partial over the one read.
        input = Self.appleMDMInput()
        input.services.items.append(Self.service("svc-apple-2", type: "APPLE_MDM"))
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM), containing: "The device list of Service svc-apple-2 wasn't read", found: ["S2"])

        input = Self.appleMDMInput()
        input.serviceDevices["svc-apple"]?.read = .partly("the page limit")
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM), containing: "read in part (the page limit)", found: ["S2"])

        input = Self.appleMDMInput()
        input.appleMDM.read = .partly("showing 1 of at least 3")
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM),
                           containing: "Apple MDM's device list was read in part (showing 1 of at least 3), so a device can't be called absent from it")
        input.appleMDM = .notRead("Apple answered 500")
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "Apple MDM's device list wasn't read (Apple answered 500)")

        // An enrolled device with no serial could be the assigned one: what no serial matches is shown, marked partial.
        input = Self.appleMDMInput()
        input.appleMDM.items.append(Self.mdm("m2", serial: nil))
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM),
                           containing: "1 of Apple MDM's devices came with no serial number, so each device found here could be one of them", found: ["S2"])
        #expect(Self.run(input).result(.missingFromAppleMDM).findings.first?.reason
                == "Assigned in Apple to Service svc-apple; no Apple MDM device with a serial number matches it.")
    }

    static func mosyleInput() -> Input {
        var input = base()
        input.services = whole([service("svc-mosyle"), service("svc-apple", type: "APPLE_MDM")])
        input.serviceDevices = ["svc-mosyle": whole(["S1", "S2", "S3"]), "svc-apple": whole([])]
        input.mosyle = .devices(whole([mosyle(" s1 "), mosyle("S3"), mosyle("S9")]))
        return input
    }

    /// Mosyle's serials join Apple's as the reconciliation joins them (stripped, upper-cased).
    @Test func assignedToTheMosyleServiceButNotInMosyleIsFound() {
        let result = Self.run(Self.mosyleInput()).result(.missingFromMosyle)
        #expect(result.findings.map(\.subject) == ["S2"])
        #expect(result.findings[0].reason.contains("Service svc-mosyle, your Mosyle org's service"))
    }

    @Test func missingFromMosyleNeedsTheSettingAndWholeReads() {
        var input = Self.mosyleInput()
        input.mosyleServiceID = nil
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle), containing: "Which Apple service is your Mosyle org isn't set")
        // The other half of the rule doesn't wait on the setting.
        #expect(Self.run(input).result(.missingFromAppleMDM).isJudged)

        input = Self.mosyleInput()
        input.mosyleServiceID = "svc-gone"
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle), containing: "isn't among the services Apple listed")

        input = Self.mosyleInput()
        input.serviceDevices["svc-mosyle"] = nil
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle), containing: "The device list of Service svc-mosyle wasn't read")

        input = Self.mosyleInput()
        input.serviceDevices["svc-mosyle"]?.read = .notRead("your role can't read this")
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle), containing: "wasn't read (your role can't read this)")

        // The side searched (Mosyle) read in part: skipped, and says so. The assigned side read in part: partial.
        input = Self.mosyleInput()
        input.mosyle = .devices(.init([Self.mosyle("S1")], read: .partly("showing 1 of at least 3")))
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle),
                           containing: "Mosyle's device list was read in part (showing 1 of at least 3), so a device can't be called absent from it")
        input = Self.mosyleInput()
        input.serviceDevices["svc-mosyle"]?.read = .partly("showing 3 of at least 5")
        Self.expectPartial(Self.run(input).result(.missingFromMosyle), containing: "The device list of Service svc-mosyle was read in part (showing 3 of at least 5)",
                           found: ["S2"])
    }

    // MARK: 2. in the MDM, not in Apple

    @Test func inAppleMDMButNotInAppleIsFound() {
        var input = Self.base()
        input.devices = Self.whole([Fleet.device("S1")])
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "S1"), Self.mdm("m9", serial: "S9"), Self.mdm("m0", serial: nil)])
        let result = Self.run(input).result(.appleMDMNotInApple)
        // A device with no serial is flagged under its Apple MDM id (the operator: "Flag them all").
        #expect(result.findings.map(\.subject) == ["S9", "m0"] && result.notes.isEmpty)
        #expect(result.findings.last?.reason == "Enrolled in Apple MDM with no serial number (listed by its Apple MDM id): can't be matched with Apple's device list.")
        #expect(result.subjectsToRecord == ["S9", "m0"])

        // Apple MDM's list read in part: partial. Apple's list (the one searched) read in part: skipped, and says which.
        var part = input
        part.appleMDM.read = .partly("showing 3 of at least 4")
        Self.expectPartial(Self.run(part).result(.appleMDMNotInApple), containing: "Apple MDM's device list was read in part", found: ["S9", "m0"])
        input.devices.read = .partly("showing 1 of at least 2")
        Self.expectSkipped(Self.run(input).result(.appleMDMNotInApple),
                           containing: "Apple's device list was read in part (showing 1 of at least 2), so a device can't be called absent from it")
        input = Self.base()
        input.appleMDM = .notRead("Apple School Manager has no Apple MDM")
        Self.expectSkipped(Self.run(input).result(.appleMDMNotInApple), containing: "Apple School Manager has no Apple MDM")
    }

    /// One rule, two screens: the finding is the reconciliation screen's Mosyle-only bucket, serial for serial.
    @Test func inMosyleButNotInAppleIsTheReconciliationsMosyleOnlyBucket() {
        var input = Self.base()
        let apple = ["S1", "S2", "s3"].map { Fleet.device($0) }
        let mosyle = [Self.mosyle("S1"), Self.mosyle("S3 "), Self.mosyle("S8"), Self.mosyle("S7"), Self.mosyle("S8")]
        input.devices = Self.whole(apple)
        input.mosyle = .devices(Self.whole(mosyle))
        let found = Self.subjects(input, .mosyleNotInApple)
        #expect(found == Reconciliation(apple: apple.map(\.resource), mosyle: mosyle).mosyleOnly.map(\.serial))
        #expect(found == ["S7", "S8"])

        input.mosyle = .devices(.init(mosyle, read: .partly("showing 5 of at least 9")))
        Self.expectPartial(Self.run(input).result(.mosyleNotInApple), containing: "Mosyle's device list was read in part (showing 5 of at least 9)",
                           found: ["S7", "S8"])
        input.mosyle = .devices(Self.whole(mosyle))
        input.devices.read = .partly("showing 3 of at least 4")
        Self.expectSkipped(Self.run(input).result(.mosyleNotInApple), containing: "Apple's device list was read in part (showing 3 of at least 4), so a device can't be called absent from it")
        input.devices = .notRead("your role can't read this")
        Self.expectSkipped(Self.run(input).result(.mosyleNotInApple), containing: "Apple's device list wasn't read (your role can't read this)")
    }

    // MARK: 3. AppleCare expiring

    static func coverageInput(_ ends: [String: [AppleCareCoverage]]) -> Input {
        var input = base()
        input.devices = whole(ends.keys.sorted().map { Fleet.device($0) })
        input.coverage = .init(ends.mapValues { .read($0) })
        return input
    }

    /// `CoverageReport`'s window: from now to now + the threshold, both ends included; an ended coverage isn't "expiring".
    @Test func appleCareExpiringFollowsTheCoverageWindowAtItsEdges() {
        let input = Self.coverageInput([
            "A-EDGE": [Fleet.coverage("ACTIVE", end: Fleet.stamp(90 * Self.day))],
            "B-PAST-EDGE": [Fleet.coverage("ACTIVE", end: Fleet.stamp(90 * Self.day + 1))],
            "C-NOW": [Fleet.coverage("ACTIVE", end: Fleet.stamp(0))],
            "D-ENDED": [Fleet.coverage("ACTIVE", end: Fleet.stamp(-1))],
            "E-INACTIVE": [Fleet.coverage("INACTIVE", end: Fleet.stamp(10 * Self.day))],
            "F-NONE": [],
            "G-TWO": [Fleet.coverage("ACTIVE", end: Fleet.stamp(20 * Self.day)), Fleet.coverage("ACTIVE", end: Fleet.stamp(30 * Self.day))],
        ])
        let result = Self.run(input).result(.appleCareExpiring)
        #expect(result.findings.map(\.subject) == ["C-NOW", "G-TWO", "A-EDGE"])
        #expect(result.findings.map(\.reason) == ["AppleCare coverage ends in less than a day.", "AppleCare coverage ends in 20 days.",
                                                  "AppleCare coverage ends in 90 days."])
        let shorter = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 89, migrationDeadlineDays: 14, quietServiceDays: 30)
        #expect(Self.subjects(input, .appleCareExpiring, shorter) == ["C-NOW", "G-TWO"])
    }

    /// The finding is the device the record sat under, whatever the record's own serial says.
    @Test func anExpiringCoverageIsItsDevicesByKey() {
        let record = AppleCareCoverage(resource: Resource(type: "appleCareCoverage", id: "c", attributes: [
            "status": .string("ACTIVE"), "endDateTime": .string(Fleet.stamp(Self.day)), "serialNumber": .string("SOMEONE-ELSE"),
        ]))
        #expect(Self.subjects(Self.coverageInput(["MINE": [record]]), .appleCareExpiring) == ["MINE"])
    }

    /// Some devices' coverage not read: partial over the rest, and says how many. None read: skipped.
    @Test func appleCareExpiringIsPartialWhenSomeCoverageWasntReadAndSkippedWhenNone() {
        var input = Self.coverageInput(["A": [Fleet.coverage("ACTIVE", end: Fleet.stamp(Self.day))], "B": [], "C": []])
        input.coverage.reads["B"] = nil
        Self.expectPartial(Self.run(input).result(.appleCareExpiring), containing: "AppleCare coverage wasn't read for 1 of 3 devices (the sweep didn't reach it)",
                           found: ["A"])
        input.coverage.reads["C"] = .notRead("your role can't read this")
        Self.expectPartial(Self.run(input).result(.appleCareExpiring), containing: "2 of 3 devices (the sweep didn't reach it; your role can't read this)",
                           found: ["A"])
        input.coverage.reads["A"] = nil
        Self.expectSkipped(Self.run(input).result(.appleCareExpiring), containing: "AppleCare coverage wasn't read for 3 of 3 devices")
        input = Self.coverageInput(["A": [Fleet.coverage("ACTIVE", end: Fleet.stamp(Self.day))]])
        input.devices.read = .partly("showing 1 of at least 2")
        Self.expectPartial(Self.run(input).result(.appleCareExpiring), containing: "Apple's device list was read in part (showing 1 of at least 2)", found: ["A"])
        input.devices = .notRead("your role can't read this")
        Self.expectSkipped(Self.run(input).result(.appleCareExpiring), containing: "Apple's device list wasn't read (your role can't read this)")
    }

    @Test func appleCareExpiringSaysWhatItCouldntJudge() {
        let input = Self.coverageInput(["A": [Fleet.coverage("ACTIVE", end: "soon")], "B": []])
        let result = Self.run(input).result(.appleCareExpiring)
        #expect(result.isJudged && result.findings.isEmpty)
        #expect(result.notes == ["1 ACTIVE coverage has an end date this app can't read: covered, but not judged."])
        let two = Self.coverageInput(["A": [Fleet.coverage("ACTIVE", end: "soon"), Fleet.coverage("ACTIVE", end: "later")], "B": []])
        #expect(Self.run(two).result(.appleCareExpiring).notes == ["2 ACTIVE coverages have an end date this app can't read: covered, but not judged."])
        let far = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 3000, migrationDeadlineDays: 14, quietServiceDays: 30)
        let clamped = Self.run(Self.coverageInput(["A": []]), far).result(.appleCareExpiring)
        #expect(clamped.title.contains("1825 days") && clamped.notes.contains { $0.contains("1825 days were used") })
    }

    /// The cap's edge: 1825 is the report's most and says nothing; 1826 is past it and says so.
    @Test func appleCareThresholdAtTheCapSaysNothingAndPastItSaysSo() {
        func notes(_ days: Int) -> [String] {
            let t = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: days, migrationDeadlineDays: 14, quietServiceDays: 30)
            return Self.run(Self.coverageInput(["A": []]), t).result(.appleCareExpiring).notes
        }
        #expect(notes(1825).isEmpty)
        #expect(notes(1826) == ["The threshold, 1826 days, is past the most the coverage report looks ahead: 1825 days were used."])
    }

    /// A device read whose only ACTIVE coverage ends on a date this app can't read is unknown: when every device read is,
    /// nothing was judged, so the rule is skipped, never "none found".
    @Test func appleCareWithEveryEndUnreadableIsSkipped() {
        let result = Self.run(Self.coverageInput(["A": [Fleet.coverage("ACTIVE", end: "soon")], "B": [Fleet.coverage("ACTIVE", end: "")]])).result(.appleCareExpiring)
        Self.expectSkipped(result, containing: "Every device's ACTIVE coverage read ends on a date this app can't read (2 devices)")
    }

    // MARK: 4. no check-in for N days

    /// `StaleDevices`' rule: whole days, floored; the threshold itself is stale; never checked in is found.
    @Test func mosyleCheckInIsStaleDevicesAtItsEdges() {
        var input = Self.base()
        let devices = [
            Self.mosyle("EDGE", checkIn: .string(Fleet.stamp(-30 * Self.day))),
            Self.mosyle("JUST-UNDER", checkIn: .string(Fleet.stamp(-30 * Self.day + 1))),
            Self.mosyle("NEVER", checkIn: nil), Self.mosyle("EMPTY", checkIn: .string("")),
            Self.mosyle("GARBLED", checkIn: .string("last week")), Self.mosyle("FRESH"),
            Self.mosyle("OLD", checkIn: .string(Fleet.stamp(-45 * Self.day))),
        ]
        input.mosyle = .devices(Self.whole(devices))
        let result = Self.run(input).result(.mosyleCheckIn)
        #expect(result.findings.map(\.subject) == StaleDevices(devices, days: 30, now: Fleet.now).rows.map(\.serial))
        #expect(Set(result.findings.map(\.subject)) == ["EDGE", "NEVER", "EMPTY", "GARBLED", "OLD"])
        let reasons = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.subject, $0.reason) })
        #expect(reasons["EDGE"] == "Last checked in to Mosyle 30 days ago.")
        #expect(reasons["NEVER"] == "Never checked in to Mosyle." && reasons["EMPTY"] == "Never checked in to Mosyle.")
        #expect(reasons["GARBLED"] == "Mosyle's last check-in isn't a date this app reads: \"last week\".")
        let longer = NeedsAttention.Thresholds(checkInDays: 31, appleCareExpiringDays: 90, migrationDeadlineDays: 14, quietServiceDays: 30)
        #expect(!Self.subjects(input, .mosyleCheckIn, longer).contains("EDGE"))
    }

    @Test func mosyleCheckInIsSkippedWithoutAWholeListOrItsColumn() {
        var input = Self.base()
        input.mosyle = .devices(.init([Self.mosyle("A")], read: .whole, notSent: ["lastCheckIn"]))
        Self.expectSkipped(Self.run(input).result(.mosyleCheckIn), containing: "Mosyle didn't send when its devices last checked in")
        input.mosyle = .devices(.init([Self.mosyle("A"), Self.mosyle("B", checkIn: nil)], read: .partly("showing 2 of at least 3")))
        Self.expectPartial(Self.run(input).result(.mosyleCheckIn), containing: "Mosyle's device list was read in part (showing 2 of at least 3)", found: ["B"])
    }

    static func appleMDMDevices() -> Input {
        var input = base()
        input.appleMDM = whole([mdm("m1", serial: "EDGE"), mdm("m2", serial: "UNDER"), mdm("m3", serial: "BLANK"), mdm("m4", serial: "NONE", family: "iPhone"),
                                mdm("m5", serial: "GARBLED")])
        input.appleMDMDetails = .init([
            "m1": .read(detail(["lastCheckInDateTime": .string(Fleet.stamp(-30 * day))])),
            "m2": .read(detail(["lastCheckInDateTime": .string(Fleet.stamp(-30 * day + 1))])),
            "m3": .read(detail([:])),
            "m4": .read(nil),
            "m5": .read(detail(["lastCheckInDateTime": .string("soon")])),
        ])
        return input
    }

    /// Apple MDM's details through the same rule; a check-in Apple didn't send is unknown, never "never".
    @Test func appleMDMCheckInIsTheSameRuleAndAMissingStampIsUnknown() {
        let result = Self.run(Self.appleMDMDevices()).result(.appleMDMCheckIn)
        #expect(result.findings.map(\.subject) == ["GARBLED", "EDGE"])
        #expect(result.findings.map(\.reason) == ["Apple MDM's last check-in isn't a date this app reads: \"soon\".", "Last checked in to Apple MDM 30 days ago."])
        #expect(result.notes == ["2 of Apple MDM's devices have no last check-in in their details: unknown, not judged."])
    }

    /// Details read for only some devices (the screen reads 50): partial over those read. None read: skipped.
    @Test func appleMDMCheckInIsPartialWhenSomeDetailsWerentRead() {
        var input = Self.appleMDMDevices()
        input.appleMDMDetails.reads["m2"] = nil
        Self.expectPartial(Self.run(input).result(.appleMDMCheckIn), containing: "Apple MDM's device detail wasn't read for 1 of 5 devices", found: ["GARBLED", "EDGE"])
        input.appleMDMDetails.reads["m3"] = .notRead("Apple answered 403")
        Self.expectPartial(Self.run(input).result(.appleMDMCheckIn), containing: "2 of 5 devices (the sweep didn't reach it; Apple answered 403)",
                           found: ["GARBLED", "EDGE"])
        input.appleMDMDetails = .init()
        Self.expectSkipped(Self.run(input).result(.appleMDMCheckIn), containing: "Apple MDM's device detail wasn't read for 5 of 5 devices")
        input = Self.appleMDMDevices()
        input.appleMDM.read = .partly("showing 5 of at least 6")
        Self.expectPartial(Self.run(input).result(.appleMDMCheckIn), containing: "Apple MDM's device list was read in part", found: ["GARBLED", "EDGE"])
    }

    // MARK: 5. FileVault and the firewall

    static func securityInput() -> Input {
        var input = base()
        input.appleMDM = whole([
            mdm("m1", serial: "MAC-OFF"), mdm("m2", serial: "MAC-ON"), mdm("m3", serial: "MAC-MISSING"), mdm("m4", serial: "MAC-TEXT"),
            mdm("m5", serial: "PHONE-OFF", family: "iPhone"), mdm("m6", serial: "PAD-OFF", family: "iPad"), mdm("m7", serial: "WHAT", family: nil),
            mdm("m8", serial: "MAC-NO-DETAILS"), mdm("m9", serial: "ODD", family: "Toaster"),
        ])
        let off = detail(["isFileVaultEnabled": .bool(false), "isFirewallEnabled": .bool(false)])
        input.appleMDMDetails = .init([
            "m1": .read(off), "m2": .read(detail(["isFileVaultEnabled": .bool(true), "isFirewallEnabled": .bool(true)])),
            "m3": .read(detail([:])), "m4": .read(detail(["isFileVaultEnabled": .string("false"), "isFirewallEnabled": .null])),
            "m5": .read(off), "m6": .read(off), "m7": .read(off), "m8": .read(nil), "m9": .read(off),
        ])
        return input
    }

    /// Macs only; a value Apple didn't send, or sent in another shape, is unknown and never off; an iPhone is never flagged.
    @Test func fileVaultAndTheFirewallOffAreFoundOnMacsOnly() {
        let report = Self.run(Self.securityInput())
        for (rule, name) in [(Rule.fileVaultOff, "FileVault"), (.firewallOff, "firewall")] {
            let result = report.result(rule)
            #expect(result.findings.map(\.subject) == ["MAC-OFF"], "\(rule)")
            #expect(result.findings.first?.reason == (rule == .fileVaultOff ? "FileVault is off." : "The firewall is off."))
            #expect(result.notes.contains("3 Macs have no \(name) value in Apple MDM's details (none sent, or not a yes or no): unknown, not counted as off."))
            #expect(result.notes.contains("2 of Apple MDM's devices came with no product family this version knows: not judged (only Macs are)."))
            #expect(result.notes.contains("Mosyle's devices aren't judged: this app reads no \(name) value from Mosyle."))
        }
    }

    /// Only a Mac's details are needed: an iPhone's unread details change nothing, a Mac's make the rule partial, and no Mac's
    /// read skips it.
    @Test func fileVaultIsPartialOnlyWhenAMacsDetailsWerentRead() {
        var input = Self.securityInput()
        input.appleMDMDetails.reads["m5"] = nil
        input.appleMDMDetails.reads["m7"] = .notRead("Apple answered 500")
        #expect(Self.run(input).result(.fileVaultOff).findings.map(\.subject) == ["MAC-OFF"])
        input.appleMDMDetails.reads["m2"] = nil
        Self.expectPartial(Self.run(input).result(.fileVaultOff), containing: "Apple MDM's device detail wasn't read for 1 of 5 Macs", found: ["MAC-OFF"])
        Self.expectPartial(Self.run(input).result(.firewallOff), containing: "1 of 5 Macs", found: ["MAC-OFF"])
        for mac in ["m1", "m3", "m4", "m8"] { input.appleMDMDetails.reads[mac] = .notRead("Apple answered 403") }
        Self.expectSkipped(Self.run(input).result(.fileVaultOff), containing: "Apple MDM's device detail wasn't read for 5 of 5 Macs")
        input = Self.securityInput()
        input.mosyle = .noMosyleOrg
        #expect(Self.run(input).result(.fileVaultOff).notes.allSatisfy { !$0.contains("Mosyle") })
        input.appleMDM = .notRead("Apple School Manager has no Apple MDM")
        Self.expectSkipped(Self.run(input).result(.fileVaultOff), containing: "Apple MDM's device list wasn't read (Apple School Manager has no Apple MDM)")
    }

    // MARK: 6. Activation Lock

    static func lockInput() -> Input {
        var input = base()
        input.devices = whole(["USER", "MDM", "OPEN", "USER-UNLOCKED", "UNCLEAR", "ODD"].map { Fleet.device($0) })
        input.activationLock = .init([
            "USER": .read(Fleet.lock(true, "USER")), "MDM": .read(Fleet.lock(true, "MDM")), "OPEN": .read(Fleet.lock(false, nil)),
            "USER-UNLOCKED": .read(Fleet.lock(false, "USER")), "UNCLEAR": .read(Fleet.lock(nil, "USER")), "ODD": .read(Fleet.lock(true, "FAMILY")),
        ])
        return input
    }

    @Test func activationLockByAPersonIsFoundAsTheReportsBlocksRelease() {
        let input = Self.lockInput()
        let result = Self.run(input).result(.activationLock)
        #expect(result.findings.map(\.subject) == ["USER"])
        let report = ActivationLockReport(input.devices.items, reads: input.activationLock.reads)
        #expect(result.findings.map(\.subject) == report.rows.filter(\.blocksRelease).map(\.device.id))
        #expect(result.findings[0].reason == "Locked by a person's Apple Account (USER): blocks redeploy and release.")
        #expect(result.notes == ["2 devices are locked by a type this version can't place, or sent no readable isLocked: can't say whether they block release."])
    }

    @Test func activationLockIsPartialWhenSomeDevicesWerentRead() {
        var input = Self.lockInput()
        input.activationLock.reads["MDM"] = nil
        Self.expectPartial(Self.run(input).result(.activationLock), containing: "Activation Lock status wasn't read for 1 of 6 devices", found: ["USER"])
        input.activationLock.reads["OPEN"] = .notRead("Apple answered 429")
        Self.expectPartial(Self.run(input).result(.activationLock), containing: "2 of 6 devices", found: ["USER"])
        input.activationLock = .init()
        Self.expectSkipped(Self.run(input).result(.activationLock), containing: "Activation Lock status wasn't read for 6 of 6 devices")
        input = Self.lockInput()
        input.devices.read = .partly("showing 6 of at least 9")
        Self.expectPartial(Self.run(input).result(.activationLock), containing: "Apple's device list was read in part (showing 6 of at least 9)", found: ["USER"])
    }

    // MARK: 7. quiet services

    static let mixedServices = [
        service("ok"), service("quiet", last: .string(Fleet.stamp(-40 * day))), service("never", last: nil),
        service("gone", status: "DELETED", last: nil), service("off-old", status: "INACTIVE", last: .string(Fleet.stamp(-40 * day))),
        service("garbled", last: .string("yesterday")), service("edge", last: .string(Fleet.stamp(-30 * day))),
        service("edge-hour", last: .string(Fleet.stamp(-30 * day - 3_600))), service("edge-second", last: .string(Fleet.stamp(-30 * day - 1))),
        service("ten", last: .string(Fleet.stamp(-10 * day))),
    ]

    /// One rule, two screens: the quiet services are `QuietServices`' rows, in its order, at every threshold.
    @Test func aQuietServiceIsExactlyQuietServices() {
        var input = Self.base()
        input.services = Self.whole(Self.mixedServices)
        for days in [1, 7, 10, 30, 31, 40, 90] {
            let t = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 14, quietServiceDays: days)
            #expect(Self.subjects(input, .quietService, t) == QuietServices(Self.mixedServices, now: Fleet.now, days: days).rows.map(\.service.id), "\(days)")
        }
        let result = Self.run(input).result(.quietService)
        #expect(Set(result.findings.map(\.subject)) == ["quiet", "never", "off-old", "garbled", "edge-hour", "edge-second"])
        let reasons = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.subject, $0.reason) })
        #expect(reasons["quiet"] == "Service quiet: last connected 40 days ago.")
        #expect(reasons["never"] == "Service never: never connected.")
        #expect(reasons["garbled"] == "Service garbled: last connected at a date this app can't read: \"yesterday\".")
    }

    @Test func aQuietServiceCantBeJudgedFromADefaultFieldsRead() {
        var input = Self.base()
        input.services = .init(Self.mixedServices, read: .whole, notSent: ["lastConnectedDateTime"])
        Self.expectSkipped(Self.run(input).result(.quietService), containing: "didn't send when the services last connected")
        input.services = .init(Self.mixedServices, read: .whole, notSent: ["status"])
        #expect(Self.run(input).result(.quietService).notes == ["Apple didn't send the services' status, so a deleted service can't be told apart and may be listed."])
        input.services = .init(Self.mixedServices, read: .partly("showing 10 of at least 12"))
        Self.expectPartial(Self.run(input).result(.quietService), containing: "The device management services list was read in part (showing 10 of at least 12)",
                           found: QuietServices(Self.mixedServices, now: Fleet.now).rows.map(\.service.id))
    }

    // MARK: 8. migration deadlines

    static func migration(_ serial: String, _ status: String?, deadline: JSONValue?) -> OrgDevice {
        var extra: JSONObject = ["isMdmMigrationCapable": .bool(true)]
        if let status { extra = extra.merging(["mdmMigrationStatus": .string(status)]) }
        if let deadline { extra = extra.merging(["mdmMigrationDeadlineDateTime": deadline]) }
        return Fleet.device(serial, extra)
    }

    static func migrationInput() -> Input {
        var input = base()
        input.devices = whole([
            migration("EDGE", "REQUESTED", deadline: .string(Fleet.stamp(15 * day - 1))),
            migration("PAST-EDGE", "REQUESTED", deadline: .string(Fleet.stamp(15 * day))),
            migration("LATE", "STARTED", deadline: .string(Fleet.stamp(-2 * day))),
            migration("TODAY", "FAILED", deadline: .string(Fleet.stamp(3_600))),
            migration("DONE", "SUCCESS", deadline: .string(Fleet.stamp(-5 * day))),
            migration("ODD", "PAUSED", deadline: .string(Fleet.stamp(day))),
            migration("NOSTATUS", nil, deadline: .string(Fleet.stamp(-day))),
            migration("GARBLED", "REQUESTED", deadline: .string("next month")),
            migration("FAR-ODD", "PAUSED", deadline: .string(Fleet.stamp(60 * day))),
            migration("NONE", "REQUESTED", deadline: nil),
        ])
        return input
    }

    /// The report's days: a deadline that reads 14 days left is near at 14; 15 isn't. Past and not done is always found.
    @Test func aMigrationDeadlineNearIsFoundByTheReportsDays() {
        let input = Self.migrationInput()
        let result = Self.run(input).result(.migrationDeadline)
        let reasons = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.subject, $0.reason) })
        #expect(Set(reasons.keys) == ["EDGE", "LATE", "TODAY"])
        #expect(reasons["EDGE"] == "Migration REQUESTED, its deadline in 14 days.")
        #expect(reasons["LATE"] == "Migration STARTED, 2 days past its deadline.")
        #expect(reasons["TODAY"] == "Migration FAILED, its deadline in less than a day.")
        let report = MigrationReport(input.devices.items, now: Fleet.now)
        #expect(Set(report.pastDue.map(\.device.id)).isSubset(of: Set(reasons.keys)))
        #expect(result.notes == ["2 devices with a deadline within 14 days or past have no migration status this version knows: not judged.",
                                 "1 device has a migration deadline this app can't read: not judged."])
        let shorter = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 13, quietServiceDays: 30)
        #expect(!Self.subjects(input, .migrationDeadline, shorter).contains("EDGE"))
        let longer = NeedsAttention.Thresholds(checkInDays: 30, appleCareExpiringDays: 90, migrationDeadlineDays: 15, quietServiceDays: 30)
        #expect(Self.subjects(input, .migrationDeadline, longer).contains("PAST-EDGE"))
    }

    @Test func aMigrationDeadlineIsPartialOverAPartList() {
        var input = Self.migrationInput()
        let complete = Self.run(input).result(.migrationDeadline).findings.map(\.subject)
        input.devices.read = .partly("showing 10 of at least 11")
        Self.expectPartial(Self.run(input).result(.migrationDeadline), containing: "Apple's device list was read in part (showing 10 of at least 11)", found: complete)
        input.devices = .notRead("your role can't read this")
        Self.expectSkipped(Self.run(input).result(.migrationDeadline), containing: "Apple's device list wasn't read (your role can't read this)")
    }

    // MARK: nothing judged is never "none found"

    /// Every Apple MDM device answered "no details" (Apple's 404): the three detail rules judged no device, so each is
    /// skipped and says why, never "none found" and never recorded.
    @Test func everyAppleMDMDeviceWithNoDetailsSkipsTheDetailRules() {
        var input = Self.base()
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "MAC1"), Self.mdm("m2", serial: "PHONE1", family: "iPhone")])
        input.appleMDMDetails = .init(["m1": .read(nil), "m2": .read(nil)])
        let report = Self.run(input)
        Self.expectSkipped(report.result(.appleMDMCheckIn), containing: "None of the 2 Apple MDM devices read has a last check-in in its details")
        Self.expectSkipped(report.result(.fileVaultOff), containing: "No Mac could be judged: 1 Mac has no FileVault value in the details read")
        Self.expectSkipped(report.result(.firewallOff), containing: "No Mac could be judged: 1 Mac has no firewall value in the details read")
        // One device with a stamp is enough to judge.
        input.appleMDMDetails.reads["m2"] = .read(Self.detail(["lastCheckInDateTime": Self.recent]))
        #expect(Self.run(input).result(.appleMDMCheckIn).isJudged)
        #expect(Self.run(input).result(.appleMDMCheckIn).notes == ["1 of Apple MDM's devices has no last check-in in its details: unknown, not judged."])
    }

    /// No Apple MDM device has a product family this version knows ("MAC", "macOS"): no Mac can be told apart, so FileVault
    /// and the firewall are skipped; and a family Apple didn't send for any device skips them too.
    @Test func noKnownProductFamilySkipsFileVaultAndTheFirewall() {
        var input = Self.base()
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "A", family: "MAC"), Self.mdm("m2", serial: "B", family: "macOS")])
        let off = Self.detail(["isFileVaultEnabled": .bool(false), "isFirewallEnabled": .bool(false)])
        input.appleMDMDetails = .init(["m1": .read(off), "m2": .read(off)])
        Self.expectSkipped(Self.run(input).result(.fileVaultOff), containing: "2 of Apple MDM's devices came with no product family this version knows")
        Self.expectSkipped(Self.run(input).result(.firewallOff), containing: "so a Mac can't be told apart")
        input.appleMDM = .init([Self.mdm("m1", serial: "A", family: nil)], read: .whole, notSent: ["productFamily"])
        Self.expectSkipped(Self.run(input).result(.fileVaultOff), containing: "Apple didn't send Apple MDM's devices' product family")
        // Every device a known family other than Mac: no Mac, judged, nothing found.
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "A", family: "iPhone")])
        #expect(Self.run(input).result(.fileVaultOff).isJudged)
    }

    /// Apple sent Apple MDM's devices without serial numbers: neither comparison can be made, so both are skipped.
    @Test func appleMDMSerialsNotSentSkipBothComparisons() {
        var input = Self.appleMDMInput()
        input.appleMDM = .init([Self.mdm("m1", serial: nil), Self.mdm("m3", serial: nil)], read: .whole, notSent: ["serialNumber"])
        Self.expectSkipped(Self.run(input).result(.appleMDMNotInApple), containing: "Apple didn't send Apple MDM's devices' serial numbers")
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "Apple didn't send Apple MDM's devices' serial numbers")
        // Sent for some and not for these: every device without one, nothing compared, on either rule.
        input.appleMDM.notSent = []
        Self.expectSkipped(Self.run(input).result(.appleMDMNotInApple), containing: "None of Apple MDM's 2 devices came with a serial number")
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM),
                           containing: "None of Apple MDM's 2 devices came with a serial number, so a device assigned to Apple MDM can't be matched with any")
    }

    /// Every service read came with no type: no Apple MDM service can be told apart, so nothing was judged.
    @Test func everyServiceWithoutATypeSkipsMissingFromAppleMDM() {
        var input = Self.appleMDMInput()
        input.services = Self.whole([Self.service("svc-a", type: nil), Self.service("svc-b", type: nil)])
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "No service came with a type this version knows (2 services)")
    }

    /// Every Activation Lock status read is unclear or a type this version can't place: nothing judged, so skipped.
    @Test func everyLockUnplacedSkipsActivationLock() {
        var input = Self.base()
        input.devices = Self.whole(["A", "B"].map { Fleet.device($0) })
        input.activationLock = .init(["A": .read(Fleet.lock(nil, "USER")), "B": .read(Fleet.lock(true, "FAMILY"))])
        Self.expectSkipped(Self.run(input).result(.activationLock), containing: "Every Activation Lock status read is unclear or a lock type this version can't place (2 devices)")
        input.activationLock.reads["B"] = .read(Fleet.lock(false, nil))
        let result = Self.run(input).result(.activationLock)
        #expect(result.isJudged && result.notes == ["1 device is locked by a type this version can't place, or sent no readable isLocked: can't say whether it blocks release."])
    }

    /// Every device near or past its deadline has a status this version doesn't know, or an unreadable deadline: skipped.
    @Test func everyMigrationUnknownSkipsTheMigrationRule() {
        var input = Self.base()
        input.devices = Self.whole([Self.migration("A", "PAUSED", deadline: .string(Fleet.stamp(Self.day))),
                                    Self.migration("B", "REQUESTED", deadline: .string("next month"))])
        Self.expectSkipped(Self.run(input).result(.migrationDeadline), containing: "(2 devices), so none could be judged")
        input.devices.items.append(Self.migration("C", "REQUESTED", deadline: .string(Fleet.stamp(60 * Self.day))))
        let result = Self.run(input).result(.migrationDeadline)
        #expect(result.isJudged && result.notes == ["1 device with a deadline within 14 days or past has no migration status this version knows: not judged.",
                                                    "1 device has a migration deadline this app can't read: not judged."])
    }

    /// FileVault's words for one Mac, and the firewall's, read as English.
    @Test func oneUnknownMacIsSaidInTheSingular() {
        var input = Self.base()
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "A"), Self.mdm("m2", serial: "B")])
        input.appleMDMDetails = .init(["m1": .read(Self.detail(["isFileVaultEnabled": .bool(true), "isFirewallEnabled": .bool(true)])), "m2": .read(Self.detail([:]))])
        input.mosyle = .noMosyleOrg
        #expect(Self.run(input).result(.fileVaultOff).notes == ["1 Mac has no FileVault value in Apple MDM's details (none sent, or not a yes or no): unknown, not counted as off."])
        #expect(Self.run(input).result(.firewallOff).notes == ["1 Mac has no firewall value in Apple MDM's details (none sent, or not a yes or no): unknown, not counted as off."])
    }

    // MARK: Mosyle devices without a serial

    /// Mosyle sent no serial numbers (the column wasn't read): neither Mosyle comparison can be made, so both are skipped,
    /// never every Apple serial and every UDID as findings.
    @Test func mosyleSerialsNotSentSkipBothComparisons() {
        var input = Self.mosyleInput()
        input.devices = Self.whole(["S1", "S2"].map { Fleet.device($0) })
        input.mosyle = .devices(.init([Self.mosyleWithoutSerial("UDID-1"), Self.mosyleWithoutSerial("UDID-2")], read: .whole, notSent: ["serialNumber"]))
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle), containing: "Mosyle didn't send its devices' serial numbers")
        Self.expectSkipped(Self.run(input).result(.mosyleNotInApple), containing: "Mosyle didn't send its devices' serial numbers")
        // Listed by UDID with no word from the column: nothing can be compared either, on either rule.
        input.mosyle = .devices(Self.whole([Self.mosyleWithoutSerial("UDID-1"), Self.mosyleWithoutSerial("UDID-2")]))
        Self.expectSkipped(Self.run(input).result(.mosyleNotInApple), containing: "None of Mosyle's 2 devices came with a serial number")
        Self.expectSkipped(Self.run(input).result(.missingFromMosyle),
                           containing: "None of Mosyle's 2 devices came with a serial number, so a device assigned to Service svc-mosyle can't be matched with any")
    }

    /// One Mosyle device listed by its UDID could be the assigned one: "missing from Mosyle" shows what no serial matches,
    /// marked partial, as the Apple MDM half does; "in Mosyle, not in Apple" flags it under its UDID (the operator: "Flag them all").
    @Test func aMosyleDeviceListedByUDIDCouldBeTheAssignedOne() {
        var input = Self.mosyleInput()
        input.devices = Self.whole(["S1", "S2", "S3"].map { Fleet.device($0) })
        input.mosyle = .devices(Self.whole([Self.mosyle("S1"), Self.mosyle("S3"), Self.mosyle("S9"), Self.mosyleWithoutSerial("UDID-2")]))
        let missing = Self.run(input).result(.missingFromMosyle)
        Self.expectPartial(missing, containing: "1 of Mosyle's devices came with no serial number (listed by UDID or by nothing), so each device found here could be one of them",
                           found: ["S2"])
        if case .partial(let why) = missing.verdict { #expect(!why.contains("at least") && !why.contains("read in part")) }
        #expect(missing.findings.first?.reason == "Assigned in Apple to Service svc-mosyle, your Mosyle org's service; no Mosyle device with a serial number matches it.")
        let notInApple = Self.run(input).result(.mosyleNotInApple)
        #expect(notInApple.isJudged && notInApple.findings.map(\.subject) == ["S9", "UDID-2"] && notInApple.notes.isEmpty)
        #expect(notInApple.findings.last?.reason == "In Mosyle with no serial number (listed by its UDID): can't be matched with Apple's device list.")
        #expect(notInApple.subjectsToRecord == ["S9", "UDID-2"])
    }

    /// A Mosyle device with no serial and no UDID has an empty id, and one whose UDID isn't an identifier can't be named
    /// either: each is counted in a note, never a finding and never dropped silently. With every assigned serial matched,
    /// "missing from Mosyle" is judged: nothing is missing, whatever the device with no serial is.
    @Test func aMosyleDeviceWithNoNameableIdIsNoted() {
        var input = Self.mosyleInput()
        input.devices = Self.whole(["S1", "S2", "S3"].map { Fleet.device($0) })
        input.mosyle = .devices(Self.whole([Self.mosyle("S1"), Self.mosyle("S2"), Self.mosyle("S3"), Self.mosyleWithoutSerial(""),
                                            Self.mosyleWithoutSerial("bad udid")]))
        let notInApple = Self.run(input).result(.mosyleNotInApple)
        #expect(notInApple.isJudged && notInApple.findings.isEmpty)
        #expect(notInApple.notes == ["2 of Mosyle's devices came with no serial number and no UDID this app can name: not listed here."])
        let missing = Self.run(input).result(.missingFromMosyle)
        #expect(missing.isJudged && missing.findings.isEmpty && missing.subjectsToRecord == [])
        var mdm = Self.base()
        mdm.devices = Self.whole([Fleet.device("S1")])
        mdm.appleMDM = Self.whole([Self.mdm("m1", serial: "S1"), Self.mdm("bad id", serial: nil), Self.mdm("m2", serial: nil)])
        let appleMDM = Self.run(mdm).result(.appleMDMNotInApple)
        #expect(appleMDM.findings.map(\.subject) == ["m2"])
        #expect(appleMDM.notes == ["1 of Apple MDM's devices came with no serial number and no id this app can name: not listed here."])
    }

    /// The reviewer's probe: 300 devices with serials, one listed without (User Enrollment reports none), and 3 assigned
    /// devices really missing. The rule is never switched off by the one: the 3 are shown, marked partial, never recorded,
    /// and it says at least 2 of them are really missing. Both halves alike.
    @Test func oneDeviceWithNoSerialMakesMissingFromPartialNotSkipped() {
        let serials = (1...300).map { String(format: "SER%04d", $0) }
        var input = Self.mosyleInput()
        input.serviceDevices["svc-mosyle"] = Self.whole(serials + ["MISS1", "MISS2", "MISS3"])
        input.mosyle = .devices(Self.whole(serials.map { Self.mosyle($0) } + [Self.mosyleWithoutSerial("ENROLLMENT-1")]))
        Self.expectPartial(Self.run(input).result(.missingFromMosyle),
                           containing: "1 of Mosyle's devices came with no serial number (listed by UDID or by nothing), so each device found here could be one of them; at least 2 of the 3 found are really missing",
                           found: ["MISS1", "MISS2", "MISS3"])
        // As many devices with no serial as found: none is surely missing, and nothing says so.
        input.mosyle = .devices(Self.whole(serials.map { Self.mosyle($0) } + (1...3).map { Self.mosyleWithoutSerial("E\($0)") }))
        let even = Self.run(input).result(.missingFromMosyle)
        if case .partial(let why) = even.verdict { #expect(why.hasPrefix("3 of Mosyle's devices") && !why.contains("at least")) } else { Issue.record("\(even.verdict)") }

        var apple = Self.appleMDMInput()
        apple.serviceDevices["svc-apple"] = Self.whole(serials + ["MISS1", "MISS2", "MISS3"])
        apple.appleMDM = Self.whole(serials.enumerated().map { Self.mdm("m\($0.offset)", serial: $0.element) } + [Self.mdm("byod", serial: nil)])
        Self.expectPartial(Self.run(apple).result(.missingFromAppleMDM),
                           containing: "1 of Apple MDM's devices came with no serial number, so each device found here could be one of them; at least 2 of the 3 found are really missing",
                           found: ["MISS1", "MISS2", "MISS3"])
        // Nothing found: every assigned serial is matched, so nothing is missing and the run is judged and recorded.
        apple.serviceDevices["svc-apple"] = Self.whole(serials)
        #expect(Self.run(apple).result(.missingFromAppleMDM).subjectsToRecord == [])
    }

    /// A service of a type this version doesn't know could be an Apple MDM service (invariant 10): said, and the rule is
    /// partial; with no other service, nothing can be compared and the rule is skipped.
    @Test func aServiceOfAnUnknownTypeIsSaid() {
        var input = Self.appleMDMInput()
        input.services.items.append(Self.service("svc-new", type: "APPLE_MDM_NEXT"))
        Self.expectPartial(Self.run(input).result(.missingFromAppleMDM),
                           containing: "1 of 4 services came with a type this version doesn't know (APPLE_MDM_NEXT), so their devices weren't looked for", found: ["S2"])
        input.services = Self.whole([Self.service("svc-new", type: "APPLE_MDM_NEXT")])
        Self.expectSkipped(Self.run(input).result(.missingFromAppleMDM), containing: "No service came with a type this version knows (1 service)")
    }

    /// One Apple MDM device, read, with no stamp: said in the singular.
    @Test func oneAppleMDMDeviceWithNoStampIsSaidInTheSingular() {
        var input = Self.base()
        input.appleMDM = Self.whole([Self.mdm("m1", serial: "A")])
        input.appleMDMDetails = .init(["m1": .read(nil)])
        Self.expectSkipped(Self.run(input).result(.appleMDMCheckIn), containing: "The 1 Apple MDM device read has no last check-in in its details")
    }

    /// A coverage record under a key no listed device has (a device gone from the list) is beside the fleet, as
    /// `CoverageReport` keeps it: an empty list read whole judges nothing missing, notes the unreadable end, and never says
    /// "every device's coverage ends on a date this app can't read".
    @Test func anUnreadableEndOfADeviceGoneFromTheListIsNotTheFleet() {
        var input = Self.base()
        input.devices = Self.whole([])
        input.coverage = .init(["GONE": .read([Fleet.coverage("ACTIVE", end: "soon")])])
        let result = Self.run(input).result(.appleCareExpiring)
        #expect(result.isJudged && result.findings.isEmpty)
        #expect(result.notes == ["1 ACTIVE coverage has an end date this app can't read: covered, but not judged."])
        // A gone device whose coverage ends soon is found, as the report counts it toward `expiring`.
        input.coverage = .init(["GONE": .read([Fleet.coverage("ACTIVE", end: Fleet.stamp(Self.day))])])
        #expect(Self.run(input).result(.appleCareExpiring).findings.map(\.subject) == ["GONE"])
    }

    // MARK: subjects, age

    /// A subject is a serial or an id, never a name; one the store can't keep is still shown, said, and not handed to it.
    @Test func subjectsAreIdentifiersAndOneThatIsntIsShownButNotRecorded() {
        var input = Self.base()
        let named = Fleet.device("SERIAL1", ["deviceName": .string("Jane Example's MacBook Pro")])
        input.devices = Self.whole([named])
        input.activationLock = .init(["SERIAL1": .read(Fleet.lock(true, "USER"))])
        input.services = Self.whole([Self.service("svc-mosyle"), Self.service("0b3a1c52-quiet", last: nil)])
        input.mosyle = .devices(Self.whole([Self.mosyle("AB CD"), Self.mosyle("SERIAL1")]))
        let report = Self.run(input)
        #expect(report.result(.activationLock).subjectsToRecord == ["SERIAL1"])
        #expect(report.result(.quietService).subjectsToRecord == ["0b3a1c52-quiet"])
        let mosyleOnly = report.result(.mosyleNotInApple)
        #expect(mosyleOnly.findings.map(\.subject) == ["AB CD"] && !mosyleOnly.findings[0].isTrackable)
        #expect(mosyleOnly.subjectsToRecord == [])
        #expect(mosyleOnly.words.contains { $0.contains("1 found can't be kept for later") })
        #expect(report.findings.allSatisfy { !$0.subject.contains("Jane") })
    }

    /// A finding from a snapshot carries its age: the oldest snapshot among the rule's inputs; a live read has none.
    @Test func aFindingCarriesTheAgeOfTheOldestSnapshotItCameFrom() {
        var input = Self.lockInput()
        let t1 = Fleet.now.addingTimeInterval(-3 * Self.day), t2 = Fleet.now.addingTimeInterval(-Self.day)
        #expect(Self.run(input).result(.activationLock).findings[0].takenAt == nil)
        input.activationLock.takenAt = t2
        #expect(Self.run(input).result(.activationLock).findings[0].takenAt == t2)
        input.devices.takenAt = t1
        let result = Self.run(input).result(.activationLock)
        #expect(result.findings[0].takenAt == t1 && result.takenAt == t1)
        // Another rule over the same device list carries the list's age only.
        #expect(Self.run(input).result(.migrationDeadline).takenAt == t1)
        input.devices.takenAt = nil
        #expect(Self.run(input).result(.migrationDeadline).takenAt == nil)
    }
}
