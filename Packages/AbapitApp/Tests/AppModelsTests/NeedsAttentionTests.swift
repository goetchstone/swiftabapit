import AppleBusiness
import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import Reports
import SQLite3
import Testing
import TestSupport

/// The Needs-attention screen (plan §8.0; docs/domains/history.md, "The Needs-attention screen"): the twelve rules over the live
/// lists and the latest snapshots, recorded only when judged whole (the operator, 2026-11-20), kept under the client's Apple org but
/// for Mosyle check-in, which is kept under the Mosyle org (the coordinating session); Dismiss and Snooze in the local history only;
/// the per-client Mosyle service setting (the operator's Q7); a switch clearing everything; an unwritable history said in its own
/// words; the CSV naming its client. Over the strict stubs, into a real `SnapshotStore`.
@MainActor
@Suite("Needs-attention screen", .serialized)
struct NeedsAttentionTests {
    static let base = ChangesTests.base
    static let day = ChangesTests.day
    /// The model's clock: twenty days after `base`.
    static let now = Date(timeIntervalSince1970: base + 20 * day)

    static func iso(_ date: Date) -> String { ReportsTests.iso(date) }

    static func service(_ id: String, name: String, type: String = "MDM", connectedDaysAgo: Double) -> Resource {
        Resource(type: "mdmServers", id: id, attributes: ["serverName": .string(name), "serverType": .string(type), "status": .string("ACTIVE"),
                                                           "lastConnectedDateTime": .string(iso(now - connectedDaysAgo * day))])
    }

    static func migrating(_ serial: String, deadlineInDays: Double) -> Resource {
        Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string("MacBook Air"), "productFamily": .string("Mac"), "status": .string("ASSIGNED"),
            "isMdmMigrationCapable": .bool(true), "mdmMigrationStatus": .string("REQUESTED"),
            "mdmMigrationDeadlineDateTime": .string(iso(now + deadlineInDays * day)),
        ])
    }

    /// Org `a` (with Mosyle org `m` in its client) holding, live: a quiet service S1 and the Mosyle service S2; a migration due in five
    /// days (MIG0001, on S1); ADEV0000000 and ADEV0000001 on S2. Mosyle lists ADEV0000000 (checked in yesterday), ADEV0000002 (silent for
    /// sixty days) and MOSONLY1, which Apple doesn't have.
    static func world(mosyle: Bool = true, history: (@MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>)? = nil) async throws -> World {
        let world = try await World.make(mosyle: mosyle, history: history)
        let stub = world.stubs["a"]!
        stub.add(devices: [migrating("MIG0001", deadlineInDays: 5)])
        stub.add(services: [service("S1", name: "Old MDM", connectedDaysAgo: 90), service("S2", name: "Mosyle", connectedDaysAgo: 1)])
        stub.assign("MIG0001", to: "S1")
        stub.assign("ADEV0000000", to: "S2")
        stub.assign("ADEV0000001", to: "S2")
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000", beat: now - day), MosyleScreenTests.device("ADEV0000002", beat: now - 60 * day),
                                       MosyleScreenTests.device("MOSONLY1", beat: now - day)], os: "mac")
        return world
    }

    /// The model over `world`, its clock at `now`: loaded, then evaluated again once the live lists are read.
    static func ready(_ world: World) async -> NeedsAttentionModel {
        let model = world.screens.attention
        model.now = { now }
        model.dates = ReportsTests.dates
        await model.load()
        await settle(world, model)
        return model
    }

    /// Waits for the live lists the rules read, then evaluates what changed.
    static func settle(_ world: World, _ model: NeedsAttentionModel) async {
        await eventually("the live lists") {
            let apple = world.devices.state != .idle && !world.devices.state.isLoading && world.devices.servicesState != .idle && !world.devices.servicesState.isLoading
            let mosyle = world.orgs.mosyleOrg == nil || (world.mosyle.devices.state != .idle && !world.mosyle.devices.state.isLoading)
            return apple && mosyle
        }
        await model.evaluate()
    }

    static func line(_ model: NeedsAttentionModel, _ rule: NeedsAttention.Rule) -> NeedsAttentionModel.Line {
        model.lines.first { $0.rule == rule }!
    }

    static func subjects(_ model: NeedsAttentionModel, _ rule: NeedsAttention.Rule) -> [String] { line(model, rule).findings.map(\.subject) }

    static func kept(_ world: World, _ org: String) async throws -> [String] {
        try await world.history!.state(org: world.orgs.store[org]!).map { "\($0.rule):\($0.subject)" }
    }

    static func isSkipped(_ line: NeedsAttentionModel.Line) -> String? { if case .skipped(let why) = line.verdict { why } else { nil } }

    // MARK: judged, partial, skipped; what is kept

    /// A rule judged over a whole read is kept (`seen`); one judged over a part read is shown, marked partial, and not kept; a skipped
    /// rule keeps nothing and says why. Spanning rules are kept under the Apple org, Mosyle check-in under the Mosyle org.
    @Test func onlyWhatWasJudgedWholeIsKeptAndUnderItsKeeper() async throws {
        let world = try await Self.world()
        // An AppleCare sweep that missed D2 (recorded), with D1's coverage ending inside the window: a part read.
        try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Self.now - 2 * Self.day,
                                        resources: ["devices": [ReportsTests.device("D1"), ReportsTests.device("D2")], "applecare": [ReportsTests.care("D1", endsInDays: 30)]],
                                        errors: ["applecare": "HTTP 500"], notes: ["applecare": "1 of 2 not read: 1 failed twice (HTTP 500)"], unread: ["applecare": ["D2"]])
        let model = await Self.ready(world)
        #expect(model.lines.map(\.rule) == NeedsAttention.Rule.allCases)
        // Judged whole, with findings.
        #expect(Self.line(model, .quietService).verdict == .judged && Self.subjects(model, .quietService) == ["S1"])
        #expect(Self.line(model, .migrationDeadline).verdict == .judged && Self.subjects(model, .migrationDeadline) == ["MIG0001"])
        #expect(Self.line(model, .mosyleNotInApple).verdict == .judged && Self.subjects(model, .mosyleNotInApple) == ["MOSONLY1"])
        #expect(Self.line(model, .mosyleCheckIn).verdict == .judged && Self.subjects(model, .mosyleCheckIn) == ["ADEV0000002"])
        // Partial: shown, marked, never kept.
        let care = Self.line(model, .appleCareExpiring)
        guard case .partial(let why) = care.verdict else { Issue.record("\(care.verdict)"); return }
        #expect(why.contains("AppleCare coverage wasn't read for 1 of 2 devices") && care.findings.map(\.subject) == ["D1"], "\(why)")
        #expect(care.findings.allSatisfy { $0.isPartial && $0.firstSeen == nil && $0.actionsBlocked?.hasPrefix("Found over a part read") == true })
        // Skipped, and why: the setting, and no snapshot of the details.
        #expect(Self.isSkipped(Self.line(model, .missingFromMosyle))?.hasPrefix("Which Apple service is your Mosyle org isn't set") == true)
        #expect(Self.isSkipped(Self.line(model, .fileVaultOff))?.hasPrefix("No snapshot has read Apple MDM details") == true)
        // Kept: the judged findings under a, Mosyle check-in under m, nothing under b, nothing partial.
        let underA = try await Self.kept(world, "a"), underM = try await Self.kept(world, "m"), underB = try await Self.kept(world, "b")
        #expect(Set(underA) == ["migration_deadline:MIG0001", "mosyle_not_in_apple:MOSONLY1", "quiet_service:S1"], "\(underA)")
        #expect(underM == ["mosyle_check_in:ADEV0000002"] && underB.isEmpty, "\(underM) \(underB)")
        // First seen is the evaluation's time; the client-spanning finding is read back from the Apple org's row.
        #expect(Self.line(model, .mosyleNotInApple).findings[0].firstSeen == Self.now && Self.line(model, .mosyleCheckIn).findings[0].firstSeen == Self.now)
        #expect(model.recordNote == nil)
    }

    /// A skipped or partial rule never calls `seen`, not even with `[]`, which would age its findings: a finding forty days unseen is
    /// still kept for both. A judged rule ages its own (the store's 30 days).
    @Test func aSkippedOrPartialRuleNeverAgesItsFindings() async throws {
        let world = try await Self.world()
        let a = world.orgs.store["a"]!, m = world.orgs.store["m"]!, old = Self.now - 40 * Self.day
        for rule in ["applecare_expiring", "filevault_off", "missing_from_mosyle", "quiet_service"] {
            try await world.history!.seen(org: a, rule: rule, subjects: ["OLD1"], at: old)
        }
        try await world.history!.seen(org: m, rule: "mosyle_check_in", subjects: ["OLD1"], at: old)
        try await world.history!.record(org: a, takenAt: Self.now - Self.day,
                                        resources: ["devices": [ReportsTests.device("D1"), ReportsTests.device("D2")], "applecare": [ReportsTests.care("D1", endsInDays: 30)]],
                                        errors: ["applecare": "HTTP 500"], unread: ["applecare": ["D2"]])
        let model = await Self.ready(world)
        #expect(Self.line(model, .appleCareExpiring).isPartial && Self.line(model, .fileVaultOff).isSkipped && Self.line(model, .missingFromMosyle).isSkipped)
        let underA = try await Self.kept(world, "a"), underM = try await Self.kept(world, "m")
        #expect(underA.contains("applecare_expiring:OLD1") && underA.contains("filevault_off:OLD1") && underA.contains("missing_from_mosyle:OLD1"), "\(underA)")
        // Judged whole: its forty-day-old row is gone.
        #expect(!underA.contains("quiet_service:OLD1") && !underM.contains("mosyle_check_in:OLD1"), "\(underA) \(underM)")
    }

    /// The sweep rules read the snapshot the Reports screen would, with that snapshot's own device list, never the live one; the screen
    /// asks Apple for no sweep and no detail. Apple MDM's list comes from a snapshot with that snapshot's devices, services and service
    /// device lists.
    @Test func snapshotRulesReadTheirSnapshotsOwnListsAndNoSweepIsSent() async throws {
        let world = try await Self.world()
        let mac = { (id: String, serial: String) in
            Resource(type: "mdm_enrolled", id: id, attributes: ["serialNumber": .string(serial), "productFamily": .string("Mac")])
        }
        try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Self.now - 3 * Self.day, resources: [
            "devices": [ReportsTests.device("SNAP1"), ReportsTests.device("SNAP2")],
            "applecare": [ReportsTests.care("SNAP1", endsInDays: 10)],
            "activation_lock": [ReportsTests.lock("SNAP1", locked: true, type: "USER"), ReportsTests.lock("SNAP2", locked: false, type: nil)],
            "mdm_servers": [Resource(type: "mdm_servers", id: "AM1", attributes: ["serverName": .string("Apple MDM"), "serverType": .string("APPLE_MDM")])],
            "assignments": [Resource(type: "assignments", id: "SNAP2", attributes: ["serverId": .string("AM1"), "serverName": .string("Apple MDM")])],
            "mdm_enrolled": [mac("M1", "SNAP1"), mac("M3", "EXTRA9")],
            "mdm_details": [Resource(type: "mdm_details", id: "M1", attributes: ["isFileVaultEnabled": .bool(false), "isFirewallEnabled": .bool(true),
                                                                                 "lastCheckInDateTime": .string(Self.iso(Self.now - 45 * Self.day))])],
        ], unread: ["applecare": [], "activation_lock": [], "mdm_details": []])
        let model = await Self.ready(world)
        #expect(Self.line(model, .appleCareExpiring).verdict == .judged && Self.subjects(model, .appleCareExpiring) == ["SNAP1"])
        #expect(Self.line(model, .activationLock).verdict == .judged && Self.subjects(model, .activationLock) == ["SNAP1"])
        #expect(Self.line(model, .fileVaultOff).verdict == .judged && Self.subjects(model, .fileVaultOff) == ["SNAP1"])
        #expect(Self.line(model, .firewallOff).verdict == .judged && Self.subjects(model, .firewallOff).isEmpty)
        // M3 had no item in a whole sweep: Apple had no details for it (`.read(nil)`), noted, never unread.
        #expect(Self.subjects(model, .appleMDMCheckIn) == ["SNAP1"] && Self.line(model, .appleMDMCheckIn).words.contains { $0.contains("1 of Apple MDM's devices has no last check-in") })
        #expect(Self.subjects(model, .appleMDMNotInApple) == ["EXTRA9"] && Self.subjects(model, .missingFromAppleMDM) == ["SNAP2"])
        for rule: NeedsAttention.Rule in [.appleCareExpiring, .activationLock, .fileVaultOff, .appleMDMNotInApple, .missingFromAppleMDM] {
            let line = Self.line(model, rule)
            #expect(line.source.first?.hasPrefix("From the snapshot of Oct 8, 2026, 3 days old") == true, "\(rule): \(line.source)")
            #expect(!line.findings.contains { $0.subject.hasPrefix("ADEV") }, "\(rule): a live device in a snapshot's rule")
        }
        let requests = world.stubs["a"]!.requests
        #expect(!requests.contains { $0.contains("appleCareCoverage") || $0.contains("activationLock") || $0.contains("/details") || $0.contains("mdmDevices") }, "\(requests)")
    }

    /// A School org has no Apple MDM: its five Apple MDM rules are skipped in words, and nothing is asked for.
    @Test func aSchoolOrgSaysItHasNoAppleMDM() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        let model = await Self.ready(world)
        for rule: NeedsAttention.Rule in [.missingFromAppleMDM, .appleMDMNotInApple, .appleMDMCheckIn, .fileVaultOff, .firewallOff] {
            #expect(Self.isSkipped(Self.line(model, rule))?.hasPrefix("Apple School Manager's API has no Apple MDM devices to read") == true, "\(rule)")
        }
        #expect(Self.isSkipped(Self.line(model, .mosyleCheckIn)) == "This client has no Mosyle Business org")
    }

    /// A Mosyle org on screen says where Needs attention runs from, and reads nothing.
    @Test func aMosyleOrgSaysWhereItRunsFrom() async throws {
        let world = try await Self.world()
        world.orgs.select("m")
        let model = world.screens.attention
        await model.load()
        #expect(model.state == .unusable(NeedsAttentionModel.mosyleWords) && model.lines.isEmpty && model.waiting == NeedsAttentionModel.mosyleWords)
        #expect(world.stubs["a"]!.requests.isEmpty)
    }

    // MARK: dismiss and snooze

    /// Dismiss hides a finding until it clears, Snooze until a date; both are rows in the local history, kept under the finding's
    /// keeper, and shown again on request. A partial finding can't be either, and says why.
    @Test func dismissAndSnoozeAreKeptAndHide() async throws {
        let world = try await Self.world()
        try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Self.now - Self.day,
                                        resources: ["devices": [ReportsTests.device("D1"), ReportsTests.device("D2")], "applecare": [ReportsTests.care("D1", endsInDays: 30)]],
                                        errors: ["applecare": "HTTP 500"], unread: ["applecare": ["D2"]])
        let model = await Self.ready(world)
        let quiet = Self.line(model, .quietService).findings[0]
        await model.dismiss(quiet)
        #expect(model.actionNote == nil && Self.line(model, .quietService).open.isEmpty && Self.line(model, .quietService).hidden == 1)
        #expect(model.shown(Self.line(model, .quietService)).findings.isEmpty)
        model.showsHidden = true
        #expect(model.shown(Self.line(model, .quietService)).findings.first?.dismissedAt == Self.now)
        model.showsHidden = false
        // Snooze a week: hidden now, shown again after it, with its first seen unchanged.
        let due = Self.line(model, .migrationDeadline).findings[0]
        await model.snooze(due, days: 7)
        #expect(Self.line(model, .migrationDeadline).open.isEmpty && Self.line(model, .migrationDeadline).findings[0].snoozedUntil == Self.now + 7 * Self.day)
        model.now = { Self.now + 8 * Self.day }
        #expect(Self.line(model, .migrationDeadline).open.map(\.subject) == ["MIG0001"] && Self.line(model, .migrationDeadline).open[0].firstSeen == Self.now)
        model.now = { Self.now }
        // A Mosyle check-in finding is dismissed under the Mosyle org.
        await model.dismiss(Self.line(model, .mosyleCheckIn).findings[0])
        let underM = try await world.history!.state(org: world.orgs.store["m"]!)
        #expect(underM.map(\.subject) == ["ADEV0000002"] && underM[0].dismissedAt == Self.now)
        #expect(try await world.history!.state(org: world.orgs.store["a"]!).filter { $0.dismissedAt != nil }.map(\.subject) == ["S1"])
        // A snooze needs a date after now; a partial finding can't be kept, so neither is done.
        await model.snooze(Self.line(model, .migrationDeadline).findings[0], until: Self.now - Self.day)
        #expect(model.actionNote == "Not snoozed: a snooze needs a date after now.")
        await model.dismiss(Self.line(model, .appleCareExpiring).findings[0])
        #expect(model.actionNote?.hasPrefix("Not dismissed: Found over a part read: not kept") == true, "\(model.actionNote ?? "")")
        #expect(try await world.history!.state(org: world.orgs.store["a"]!).allSatisfy { $0.rule != "applecare_expiring" })
    }

    // MARK: the Mosyle service setting (Q7)

    /// None by default, so "missing from Mosyle" is skipped and says so; set, it is judged; an id Apple no longer lists is said and the
    /// rule skipped. Per client: another client has its own, and Settings shows it only for a client with both orgs.
    @Test func theMosyleServiceSettingNoneSetAndStale() async throws {
        let world = try await Self.world()
        let model = await Self.ready(world)
        #expect(model.mosyleServiceID == nil)
        var setting = try #require(model.serviceSetting)
        #expect(setting.selected.isEmpty && setting.words.hasPrefix("Not set, so “missing from Mosyle” is skipped"))
        #expect(setting.options.map(\.id) == ["", "S1", "S2"] && setting.options.map(\.label) == ["Not set", "Old MDM (MDM)", "Mosyle (MDM)"])
        #expect(Self.isSkipped(Self.line(model, .missingFromMosyle))?.contains("isn't set") == true)
        // Set: judged. ADEV0000001 is assigned to S2 and isn't in Mosyle. Until the rules run again, the screen says what it shows is older.
        #expect(model.updating == nil)
        model.setMosyleService("S2")
        #expect(model.mosyleServiceID == "S2" && model.settingNote == nil && model.updating?.hasPrefix("Judging again") == true)
        await model.evaluate()
        #expect(model.updating == nil)
        #expect(Self.line(model, .missingFromMosyle).verdict == .judged && Self.subjects(model, .missingFromMosyle) == ["ADEV0000001"])
        setting = try #require(model.serviceSetting)
        #expect(setting.selected == "S2" && setting.words == "Set: Mosyle. Only its id is kept, on this Mac; its name is read from Apple each time.")
        // Stale: an id Apple doesn't list any more is said, and the rule skipped, never judged against nothing.
        model.setMosyleService("GONE1")
        await model.evaluate()
        #expect(Self.isSkipped(Self.line(model, .missingFromMosyle)) == "The service set as your Mosyle org isn't among the services Apple listed")
        setting = try #require(model.serviceSetting)
        #expect(setting.words.hasPrefix("The service set (id GONE1) isn't among the services Apple lists now") && setting.options.last?.id == "GONE1")
        // A name or words are never stored as an id.
        model.setMosyleService("two words")
        #expect(model.mosyleServiceID == "GONE1" && model.settingNote == LocalSettings.Failure.notAServiceID.message)
        // Another client: its own setting (none), and no Mosyle org, so Settings doesn't show it.
        world.orgs.select("b")
        #expect(model.mosyleServiceID == nil && model.serviceSetting == nil)
        world.orgs.select("a")
        #expect(model.mosyleServiceID == "GONE1")
        // A client with no Mosyle org: never shown.
        let alone = try await World.make()
        #expect(alone.screens.attention.serviceSetting == nil)
    }

    /// The Mosyle service's own device list failing is said, and "missing from Mosyle" skipped: never judged as a service with no devices.
    @Test func aServiceListThatFailedIsSaidNotJudgedEmpty() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.queue(500, for: "/v1/mdmServers/S2/relationships/devices")
        let model = await Self.ready(world)
        model.setMosyleService("S2")
        await model.evaluate()
        let why = try #require(Self.isSkipped(Self.line(model, .missingFromMosyle)))
        #expect(why.hasPrefix("The device list of Mosyle wasn't read (") && why.contains("HTTP 500"), "\(why)")
    }

    // MARK: one client at a time

    /// A switch clears everything at once: no line, finding, note, source or CSV of the old client under the new one.
    @Test func aSwitchClearsEverythingAtOnce() async throws {
        let world = try await Self.world()
        let model = await Self.ready(world)
        await model.dismiss(Self.line(model, .quietService).findings[0])
        model.showsHidden = true
        await model.snooze(Self.line(model, .migrationDeadline).findings[0], until: Self.now - Self.day)
        #expect(!model.lines.isEmpty && model.actionNote != nil && !model.sources.isEmpty)
        world.orgs.select("b")
        #expect(model.lines.isEmpty && model.summary == nil && model.sources.isEmpty && model.state == .idle)
        #expect(model.actionNote == nil && model.recordNote == nil && model.settingNote == nil && !model.showsHidden && model.exportBlocked != nil)
        await model.load()
        await Self.settle(world, model)
        let text = model.lines.flatMap { $0.findings.map(\.subject) + $0.words + $0.source }.joined(separator: "\n")
        #expect(!text.contains("S1") && !text.contains("MIG0001") && !text.contains("MOSONLY1") && !model.csv().contains("MIG0001"), "\(text)")
    }

    /// A read or an evaluation that returns after a switch is dropped: nothing of a shows under b.
    @Test func aReadOrAnEvaluationThatReturnsAfterASwitchIsDropped() async throws {
        for stage in ["load", "evaluate"] {
            let world = try await Self.world()
            // a's own snapshot: its AppleCare finding A1 must never show under b.
            try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Self.now - Self.day,
                                            resources: ["devices": [ReportsTests.device("A1")], "applecare": [ReportsTests.care("A1", endsInDays: 10)]])
            let model = world.screens.attention
            model.now = { Self.now }
            await model.load()
            await Self.settle(world, model)
            #expect(!model.lines.isEmpty)
            var fired = false
            model.afterAwait = { at in
                guard at == stage, !fired else { return }
                fired = true
                world.orgs.select("b")
            }
            if stage == "load" { await model.load() } else { await model.evaluate(force: true) }
            let subjects = model.lines.flatMap(\.findings).map(\.subject)
            #expect(fired && !subjects.contains { ["A1", "S1", "MIG0001", "MOSONLY1", "ADEV0000002"].contains($0) }, "\(stage): \(subjects)")
            // Nothing was kept under b from a's data.
            #expect(try await Self.kept(world, "b").isEmpty, "\(stage)")
        }
    }

    // MARK: a history that can't be written

    /// A file from a newer version is read and never written: what was found is shown, not kept, and says so in the store's own words;
    /// a dismiss says it can't be written. A file this process can't write (version 2 at mode 0400) says its own words too.
    @Test func anUnwritableHistoryIsSaidInItsOwnWords() async throws {
        for newer in [true, false] {
            let folder = try CollectorTests.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            // Written by this version first: a finding is kept, so Dismiss has a row to try.
            let writable = try SnapshotStore(storage: .folder(folder), appVersion: "test")
            let prepared = try await Self.world(history: { .success(writable) })
            _ = await Self.ready(prepared)
            #expect(try await Self.kept(prepared, "a").contains("quiet_service:S1"))
            let path = folder.appending(path: SnapshotStore.fileName).path
            try Self.sql(path, newer ? "PRAGMA user_version = 9" : "ALTER TABLE snapshots DROP COLUMN unread; PRAGMA user_version = 2")
            if !newer { #expect(chmod(path, 0o400) == 0) }
            defer { chmod(path, 0o600) }
            let store = try SnapshotStore(storage: .folder(folder), appVersion: "test")
            let failure: SnapshotStore.Failure = newer ? .readOnly(version: 9) : .notWritable(version: 2)
            #expect(store.access == (newer ? .readOnly(version: 9) : .notWritable(version: 2)))
            let world = try await Self.world(history: { .success(store) })
            // A finding only this run makes: never kept.
            world.mosyleStub.add(devices: [MosyleScreenTests.device("MOSONLY2", beat: Self.now - Self.day)], os: "mac")
            let model = await Self.ready(world)
            #expect(model.recordNote == "What was found isn't kept for later (first seen, Dismiss, Snooze): \(failure.message)", "\(model.recordNote ?? "")")
            // The finding kept before is still read; a new one isn't kept, and says why.
            #expect(Self.line(model, .quietService).findings[0].firstSeen != nil)
            let new = try #require(Self.line(model, .mosyleNotInApple).findings.first { $0.subject == "MOSONLY2" })
            #expect(new.firstSeen == nil && new.actionsBlocked == model.recordNote)
            await model.dismiss(Self.line(model, .quietService).findings[0])
            #expect(model.actionNote == "Not dismissed: \(failure.message)", "\(model.actionNote ?? "")")
            await model.snooze(new, days: 7)
            #expect(model.actionNote == "Not snoozed: \(model.recordNote ?? "")")
            #expect(try await store.state(org: world.orgs.store["a"]!).allSatisfy { $0.dismissedAt == nil })
        }
    }

    /// Runs SQL on the file from outside the store.
    static func sql(_ path: String, _ text: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A history that won't open: the live rules are still judged and shown, the snapshot rules say why, and nothing is kept.
    @Test func aHistoryThatWontOpenIsSaid() async throws {
        let failure = SnapshotStore.Failure.readOnly(version: 9)
        let world = try await Self.world(history: { .failure(failure) })
        let model = await Self.ready(world)
        #expect(model.state == .failed(failure.message))
        #expect(Self.line(model, .quietService).verdict == .judged && Self.line(model, .quietService).findings[0].firstSeen == nil)
        #expect(Self.isSkipped(Self.line(model, .appleCareExpiring)) == "The snapshot history couldn't be read: \(failure.message)")
        #expect(model.recordNote == "What was found isn't kept for later (first seen, Dismiss, Snooze): \(failure.message)")
    }

    // MARK: the CSV and the Overview's card

    /// The CSV names its client (only when the app shows clients), marks partial and skipped rules in its first column, holds every
    /// finding with its state, and a row for each rule with none.
    @Test func theCSVNamesItsClientAndMarksPartialRows() async throws {
        let world = try await Self.world()
        try await world.history!.record(org: world.orgs.store["a"]!, takenAt: Self.now - Self.day,
                                        resources: ["devices": [ReportsTests.device("D1"), ReportsTests.device("D2")], "applecare": [ReportsTests.care("D1", endsInDays: 30)]],
                                        errors: ["applecare": "HTTP 500"], unread: ["applecare": ["D2"]])
        let model = await Self.ready(world)
        #expect(world.orgs.showsClients && model.exportFileName == "Org a - needs attention 20261011.csv")
        #expect(model.exportWords.hasSuffix("It is client \"Org a\"'s data only.") && model.exportBlocked == nil)
        await model.dismiss(Self.line(model, .quietService).findings[0])
        let rows = model.csv().split(separator: "\r\n").map(String.init)
        #expect(rows[0] == "id,verdict,rule,title,reason,status,firstSeen,dataFrom")
        #expect(rows.contains { $0.hasPrefix("D1,partial: ") && $0.contains(",applecare_expiring,") && $0.contains(",not kept,,") }, "\(rows)")
        #expect(rows.contains { $0.hasPrefix("S1,judged,quiet_service,") && $0.contains(",dismissed 2026-10-11T14:13:20Z,2026-10-11T14:13:20Z,") }, "\(rows)")
        #expect(rows.contains { $0.contains("skipped: Which Apple service is your Mosyle org isn't set") && $0.contains(",not judged,,,") }, "\(rows)")
        // A rule judged with nothing found says so in its own row.
        #expect(rows.contains { $0.hasPrefix(",judged,mosyle_check_in,") == false && $0.hasPrefix("ADEV0000002,judged,mosyle_check_in,") }, "\(rows)")
        // With one client, no client is named.
        let alone = try await World.make(profiles: [World.profile("a")])
        let single = alone.screens.attention
        single.now = { Self.now }
        #expect(!alone.orgs.showsClients && single.exportFileName == "needs attention 20261011.csv" && !single.exportWords.contains("client"))
    }

    /// The Overview's card counts only: open findings per rule, the rules skipped; a dismissed finding isn't counted.
    @Test func theOverviewCountsOpenFindingsAndSkippedRules() async throws {
        let world = try await Self.world()
        let model = world.screens.attention
        #expect(model.summary == nil)
        _ = await Self.ready(world)
        var summary = try #require(model.summary)
        #expect(summary.rows.map(\.rule) == [.mosyleNotInApple, .mosyleCheckIn, .quietService, .migrationDeadline] && summary.open == 4, "\(summary.rows.map(\.rule))")
        #expect(summary.skipped.count == 8 && summary.skippedWords == "8 of 12 rules skipped: open Needs Attention to see why.")
        await model.dismiss(Self.line(model, .quietService).findings[0])
        summary = try #require(model.summary)
        #expect(!summary.rows.contains { $0.rule == .quietService } && summary.open == 3)
    }

    /// The demo's history gives the screenshot first-seen dates and a snooze, in its own (memory) store.
    @Test func theDemoSeedsFirstSeenAndASnooze() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(services: [Self.service("DEMOSVC0002", name: "Jamf Pro (old)", connectedDaysAgo: 47),
                                         Self.service("DEMOSVC0003", name: "Apple Configurator", type: "APPLE_CONFIGURATOR", connectedDaysAgo: 40)])
        await DemoHistory.seedAttention(world.history!, org: world.orgs.store["a"]!, now: Self.now)
        let model = await Self.ready(world)
        let quiet = Self.line(model, .quietService)
        #expect(quiet.findings.map(\.subject) == ["DEMOSVC0002", "DEMOSVC0003"])
        #expect(quiet.findings[0].firstSeen == Self.now - 12 * Self.day && quiet.open.map(\.subject) == ["DEMOSVC0002"] && quiet.hidden == 1)
    }

    /// A rule lists at most `displayLimit` findings and says the rest are in the CSV.
    @Test func aLongRuleIsCappedAndSaysSo() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.add(services: (1...5).map { Self.service("Q\($0)", name: "Quiet \($0)", connectedDaysAgo: 60) })
        let model = await Self.ready(world)
        model.displayLimit = 2
        let shown = model.shown(Self.line(model, .quietService))
        #expect(shown.findings.count == 2 && shown.capNote == "Showing 2 of 6: the rest are in the CSV export.")
        #expect(model.csv().split(separator: "\r\n").filter { $0.contains(",quiet_service,") }.count == 6)
    }
}
