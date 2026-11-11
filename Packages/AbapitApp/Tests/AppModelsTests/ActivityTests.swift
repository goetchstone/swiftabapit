import AppleBusiness
import AppleModels
import AppModels
import Foundation
import JSONAPI
import Reports
import Testing
import TestSupport

/// Activity's screen model (invariant 8's home): the audit log over a checked range and Apple's own filters, Reports'
/// views over the one read with nothing dropped, every state said, and an org switch, a superseded load or a refresh
/// leaving nothing of the old read (failure-log 2026-10-16, "the screen models had no tests").
@MainActor
@Suite("Activity", .serialized)
struct ActivityTests {
    static let hour: TimeInterval = 3_600
    /// 1,000 as the model formats it, in this run's locale.
    static let thousand = 1_000.formatted()

    /// An event `hoursAgo` before now: the stub filters by range against its own clock, which is now.
    static func event(_ id: String, hoursAgo: Double, type: String = "DEVICE_ADDED_TO_ORG", actor: String = "A1", subject: String = "S1",
                      extra: JSONObject = [:]) -> Resource {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var attributes: JSONObject = [
            "eventDateTime": .string(format.string(from: Date().addingTimeInterval(-hoursAgo * hour))), "type": .string(type),
            "category": .string("DEVICE_INVENTORY"), "actorType": .string("API_USER"), "actorId": .string(actor), "actorName": .string("Key \(actor)"),
            "subjectType": .string("DEVICE"), "subjectId": .string(subject), "outcome": .string("SUCCESS"),
        ]
        for (key, value) in extra.members { attributes[key] = value }
        return Resource(type: "auditEvents", id: id, attributes: attributes)
    }

    static func audit(_ world: World, _ org: String = "a") -> [String] { world.stubs[org]!.requests.filter { $0.contains("/v1/auditEvents") } }

    static func settled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) audit reads finished, \(world.activity.readsFinished) so far") { world.activity.readsFinished >= reads }
    }

    static func loaded(_ state: LoadState) -> Bool { if case .loaded = state { true } else { false } }

    static let auditPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/auditEvents" }
    static let laterAuditPages: @Sendable (URL) -> Bool = { $0.path() == "/v1/auditEvents" && ($0.query() ?? "").contains("cursor=") }

    // MARK: the read

    /// The default range is the last seven days up to the read, with no filter; Apple's range is the stub's, so an event
    /// eight days old isn't read.
    @Test func theDefaultReadIsTheLastSevenDays() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Self.event("e1", hoursAgo: 2), Self.event("e2", hoursAgo: 24 * 6.5), Self.event("old", hoursAgo: 24 * 8)])
        world.activity.load()
        await Self.settled(world, 1)
        #expect(Self.loaded(world.activity.state), "\(world.activity.state)")
        #expect(Set(world.activity.rows.map(\.event.id)) == ["e1", "e2"])
        let query = try #require(world.activity.query)
        #expect(query.end.timeIntervalSince(query.start) == 7 * 86_400)
        #expect(abs(query.end.timeIntervalSinceNow) < 60)
        let sent = Self.audit(world)
        #expect(sent.count == 1 && !sent[0].contains("filter%5Btype%5D") && !sent[0].contains("Id%5D"), "\(sent)")
        // Newest first by default.
        #expect(world.activity.shown.map(\.event.id) == ["e1", "e2"])
        // An unforced load of the same org reads nothing more.
        world.activity.load()
        #expect(Self.audit(world).count == 1 && Self.loaded(world.activity.state))
    }

    /// Type, actor and subject go to Apple as its filters, and Apple's answer is what shows: the client filters nothing.
    @Test func theFiltersAreApples() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([
            Self.event("e1", hoursAgo: 1), Self.event("e2", hoursAgo: 2, type: "ROLE_CREATED"),
            Self.event("e3", hoursAgo: 3, type: "ROLE_CREATED", actor: "A2"), Self.event("e4", hoursAgo: 4, type: "ROLE_CREATED", subject: "S2"),
        ])
        world.activity.draft.type = .roleCreated
        world.activity.draft.actorID = " A1 "
        world.activity.draft.subjectID = "S1"
        #expect(world.activity.apply())
        await Self.settled(world, 1)
        #expect(world.activity.rows.map(\.event.id) == ["e2"])
        let sent = try #require(Self.audit(world).last)
        for part in ["filter%5Btype%5D=ROLE_CREATED", "filter%5BactorId%5D=A1", "filter%5BsubjectId%5D=S1"] {
            #expect(sent.contains(part), "\(sent) lacks \(part)")
        }
        #expect(world.activity.applied.actorID == "A1", "an id is trimmed before it is checked and sent")
        #expect(world.activity.applied.rangeName == "The last 7 days")
        #expect({ var f = AuditFilter(); f.days = 1; return f.rangeName }() == "The last day")
        #expect({ var f = AuditFilter(); f.days = nil; return f.rangeName }() == "A custom range")
        #expect(world.activity.applied.summary == "Apple filtered this read to type Role created, actor A1, subject S1: the views count only these events.")
        // Back to every type: the next read sends no type filter.
        world.activity.draft = AuditFilter()
        #expect(world.activity.apply())
        await Self.settled(world, 2)
        #expect(!(Self.audit(world).last ?? "").contains("filter%5Btype%5D"))
        #expect(world.activity.rows.count == 4 && world.activity.applied.summary == nil)
    }

    /// A range or an id `AuditQuery` refuses is refused when it is set, with the reason in words; the last good read stays
    /// and nothing is sent.
    @Test func aRangeIsCheckedWhenSetAndTheReasonSaid() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Self.event("e1", hoursAgo: 1)])
        world.activity.load()
        await Self.settled(world, 1)
        let now = Date()
        let refused: [(AuditFilter, String)] = [
            ({ var f = AuditFilter(); f.days = 366; return f }(), "The audit log is read at most 365 days at a time."),
            ({ var f = AuditFilter(); f.days = 0; return f }(), "The range must start before it ends."),
            ({ var f = AuditFilter(); f.days = nil; f.start = now; f.end = now.addingTimeInterval(-60); return f }(), "The range must start before it ends."),
            ({ var f = AuditFilter(); f.days = nil; f.start = now.addingTimeInterval(-366 * 86_400); f.end = now; return f }(),
             "The audit log is read at most 365 days at a time."),
            ({ var f = AuditFilter(); f.days = nil; f.start = Date(timeIntervalSince1970: -86_400); f.end = now; return f }(),
             "The range must fall between 1970 and 9999."),
            ({ var f = AuditFilter(); f.actorID = "A1,A2"; return f }(), "The actor ID can hold only letters, digits, -, _ and ., as Apple's IDs do."),
            ({ var f = AuditFilter(); f.subjectID = "S 1"; return f }(), "The subject ID can hold only letters, digits, -, _ and ., as Apple's IDs do."),
            // Phase 2b review L8: the length and the leading dot in their own words, not the characters'.
            ({ var f = AuditFilter(); f.actorID = String(repeating: "A", count: 129); return f }(),
             "The actor ID is longer than Apple's IDs: at most 128 characters."),
            ({ var f = AuditFilter(); f.actorID = ".hidden"; return f }(), "The actor ID can't start with a dot, as Apple's IDs don't."),
            ({ var f = AuditFilter(); f.subjectID = "." + String(repeating: "S", count: 200); return f }(),
             "The subject ID can't start with a dot, as Apple's IDs don't."),
            ({ var f = AuditFilter(); f.subjectID = ".hid den"; return f }(), "The subject ID can hold only letters, digits, -, _ and ., as Apple's IDs do."),
            ({ var f = AuditFilter(); f.actorID = "A1"; f.subjectID = String(repeating: "s", count: 129); return f }(),
             "The subject ID is longer than Apple's IDs: at most 128 characters."),
            ({ var f = AuditFilter(); f.actorID = "A\u{301}1"; return f }(), "The actor ID can hold only letters, digits, -, _ and ., as Apple's IDs do."),
        ]
        for (filter, words) in refused {
            #expect(filter.problem(now: now) == words, "\(filter)")
            world.activity.draft = filter
            #expect(world.activity.draftProblem == words)
            #expect(!world.activity.apply())
            #expect(world.activity.problem == words)
            #expect(world.activity.applied.days == 7 && world.activity.applied.actorID.isEmpty && world.activity.applied.subjectID.isEmpty)
        }
        #expect(Self.audit(world).count == 1, "a refused range was sent")
        #expect(world.activity.rows.map(\.event.id) == ["e1"] && Self.loaded(world.activity.state))
        // The longest range there is, and a custom one, are read.
        world.activity.draft = AuditFilter()
        world.activity.draft.days = 365
        #expect(world.activity.draftProblem == nil && world.activity.apply())
        #expect(world.activity.problem == nil)
        await Self.settled(world, 2)
        world.activity.draft.days = nil
        world.activity.draft.start = now.addingTimeInterval(-2 * Self.hour)
        world.activity.draft.end = now
        #expect(world.activity.apply())
        await Self.settled(world, 3)
        let query = try #require(world.activity.query)
        #expect(query.start == Date(timeIntervalSince1970: now.addingTimeInterval(-2 * Self.hour).timeIntervalSince1970.rounded(.down)))
        #expect(world.activity.rows.map(\.event.id) == ["e1"])
    }

    // MARK: switching, superseding, refreshing

    /// An org switch clears the rows, the selection, the filters and the CSV at once, then reads the new org.
    @Test func anOrgSwitchClearsTheScreenAndReadsAgain() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Self.event("a1", hoursAgo: 1, subject: "ADEV0000001")])
        world.stubs["b"]!.add([Self.event("b1", hoursAgo: 1), Self.event("b2", hoursAgo: 2)])
        world.activity.draft.subjectID = "ADEV0000001"
        #expect(world.activity.apply())
        await Self.settled(world, 1)
        world.activity.selection = world.activity.shown.first?.id
        #expect(world.activity.selected?.event.id == "a1")
        world.gates["b"]!.hold("b", Self.auditPages)

        world.orgs.select("b")
        #expect(world.activity.rows.isEmpty && world.activity.selection == nil && world.activity.selected == nil)
        #expect(!world.activity.csv().contains("a1"))
        #expect(world.activity.applied == world.activity.draft && world.activity.applied.subjectID.isEmpty, "org a's subject filter was kept")
        #expect(world.activity.state.isLoading, "\(world.activity.state)")
        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        #expect(Set(world.activity.rows.map(\.event.id)) == ["b1", "b2"])
        #expect(!(Self.audit(world, "b").last ?? "").contains("filter%5BsubjectId%5D"))
    }

    /// A read still in flight at the switch, and a page already answered and waiting in its stream, land nowhere.
    @Test func aSupersededLoadWritesNothing() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<1_500).map { Self.event("a\($0)", hoursAgo: 1 + Double($0) / 1_000) })
        world.stubs["b"]!.add([Self.event("b1", hoursAgo: 1)])
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAuditPages)
        world.activity.load()
        await eventually("a's first page") { world.activity.rows.count == 1_000 }
        world.gates["b"]!.hold("b", Self.auditPages)
        // Org a's second page is answered and waits, unread, for a loop the switch is about to cancel.
        world.buffer("a", release: "later")
        world.orgs.select("b")
        await Self.settled(world, 1)
        #expect(world.activity.rows.isEmpty, "\(world.activity.rows.count) of org a's events landed on org b")
        #expect(world.activity.state == .loading(count: 0), "\(world.activity.state)")
        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        #expect(world.activity.rows.map(\.event.id) == ["b1"])
        #expect(Self.loaded(world.activity.state))
    }

    /// A read whose error is already on its way when the org switches says nothing on the new org's screen.
    @Test func aSupersededReadsErrorSaysNothing() async throws {
        let world = try await World.make()
        world.stubs["b"]!.add([Self.event("b1", hoursAgo: 1)])
        let gate = world.gates["a"]!
        gate.hold("all", Self.auditPages)
        world.activity.load()
        await eventually("a's read held") { gate.held == 1 }
        world.gates["b"]!.hold("b", Self.auditPages)
        world.stubs["a"]!.queue(500, for: "/v1/auditEvents")
        // Org a's 500 is answered and waits in its stream for a loop the switch is about to cancel.
        world.buffer("a", release: "all")
        world.orgs.select("b")
        await Self.settled(world, 1)
        #expect(world.activity.state == .loading(count: 0), "org a's failure landed on org b: \(world.activity.state)")
        world.gates["b"]!.release("b")
        await Self.settled(world, 2)
        #expect(world.activity.rows.map(\.event.id) == ["b1"] && Self.loaded(world.activity.state))
    }

    /// Refresh during a load cancels it: the old read's pages never mix into the new one, which is whole.
    @Test func aRefreshDuringALoadReadsAgainWhole() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add((0..<1_500).map { Self.event("a\($0)", hoursAgo: 1 + Double($0) / 1_000) })
        let gate = world.gates["a"]!
        gate.hold("later", Self.laterAuditPages)
        world.activity.load()
        await eventually("a's first page") { world.activity.rows.count == 1_000 }
        world.activity.selection = 3
        gate.hold("all", Self.auditPages)
        world.activity.load(force: true)
        #expect(world.activity.rows.isEmpty && world.activity.selection == nil, "a refresh keeps a selection that names another event")
        gate.release("later")
        await Self.settled(world, 1)
        #expect(world.activity.rows.isEmpty && world.activity.state == .loading(count: 0), "\(world.activity.state)")
        gate.release("all")
        await Self.settled(world, 2)
        #expect(world.activity.rows.count == 1_500 && Set(world.activity.rows.map(\.event.id)).count == 1_500)
        #expect(world.activity.rows.map(\.id) == Array(0..<1_500), "a row's id is its place in the read")
        #expect(Self.loaded(world.activity.state) && !world.activity.truncated)
    }

    // MARK: saying why

    /// A role that can't read the audit log is told so, never shown an empty table.
    @Test func aForbiddenReadSaysSo() async throws {
        let world = try await World.make()
        world.stubs["a"]!.forbid("/v1/auditEvents")
        world.activity.load()
        await Self.settled(world, 1)
        #expect(world.activity.state == .forbidden)
        #expect(world.activity.emptyText == "Your role can't read the audit log.")
        #expect(world.activity.exportBlocked == ScreenWords.nothingToExport && world.activity.shown.isEmpty)
    }

    /// Apple School Manager has no audit log: said in words, and nothing is sent.
    @Test func aSchoolOrgIsNotInScope() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.activity.load()
        await Self.settled(world, 1)
        #expect(world.activity.state == .notInScope("Apple School Manager's API has no audit events to read."))
        #expect(world.activity.emptyText == "Apple School Manager's API has no audit events to read.")
        #expect(world.activity.counts(.subscriptions) == nil)
        #expect(Self.audit(world).isEmpty && world.stubs["a"]!.requests.isEmpty, "\(world.stubs["a"]!.requests)")
    }

    /// No org, and an org this version can't read, say why.
    @Test func anUnusableOrgSaysWhy() async throws {
        let world = try await World.make(profiles: [World.unusable])
        world.activity.load()
        if case .unusable(let why) = world.activity.state { #expect(why.contains("can't be used")) } else { Issue.record("\(world.activity.state)") }
        #expect(world.activity.emptyText?.contains("can't be used") == true)
        let none = try await World.make(profiles: [])
        none.activity.load()
        if case .unusable(let why) = none.activity.state { #expect(why.hasPrefix("No organization yet")) } else { Issue.record("\(none.activity.state)") }
    }

    /// A list the page cap cut says "showing N of more", counts nothing by type, and still exports, as Devices does.
    @Test func aListCutAtThePageCapIsSaid() async throws {
        let world = try await World.make(pageCap: 1)
        world.stubs["a"]!.add((0..<1_001).map { Self.event("a\($0)", hoursAgo: 1 + Double($0) / 1_000) })
        world.activity.load()
        await Self.settled(world, 1)
        #expect(Self.loaded(world.activity.state) && world.activity.truncated && world.activity.rows.count == 1_000)
        #expect(world.activity.counts(.deviceLifecycle) == nil, "a count over a list cut short")
        #expect(world.activity.summary(for: .deviceLifecycle) == "\(Self.thousand) of the \(Self.thousand) events read: the list stopped at the page limit.")
        #expect(world.activity.exportBlocked == nil)
    }

    /// A read that fails part-way keeps what it read, says so, counts nothing and doesn't export.
    @Test func aReadThatFailsPartWayIsPartial() async throws {
        let world = try await World.make()
        let stub = world.stubs["a"]!, gate = world.gates["a"]!
        stub.add((0..<1_001).map { Self.event("a\($0)", hoursAgo: 1 + Double($0) / 1_000) })
        gate.hold("later", Self.laterAuditPages)
        world.activity.load()
        await eventually("a's first page") { world.activity.rows.count == 1_000 && gate.held == 1 }
        #expect(world.activity.exportBlocked == "The list is still loading.")
        #expect(world.activity.counts(.deviceLifecycle) == nil)
        #expect(world.activity.summary(for: .audit) == "\(Self.thousand) events read so far.")
        stub.queue(500, for: "/v1/auditEvents")
        gate.release("later")
        await Self.settled(world, 1)
        #expect(world.activity.state == .failed("Apple's service failed (HTTP 500). Try again later."))
        #expect(world.activity.partialCount == 1_000)
        #expect(world.activity.exportBlocked?.hasPrefix("The list is partial: \(Self.thousand) events") == true)
        #expect(world.activity.counts(.deviceLifecycle) == nil)
        #expect(world.activity.summary(for: .deviceLifecycle) == "\(Self.thousand) of the \(Self.thousand) events read before the error.")
    }

    /// A range with no events says so, in words that depend on the filters, the pane and the search.
    @Test func anEmptyTableSaysWhy() async throws {
        let world = try await World.make()
        world.activity.load()
        await Self.settled(world, 1)
        #expect(world.activity.emptyText == "No events in this range.")
        world.activity.draft.actorID = "A9"
        #expect(world.activity.apply())
        await Self.settled(world, 2)
        #expect(world.activity.emptyText == "No events in this range match Apple's filters.")
        world.stubs["a"]!.add([Self.event("e1", hoursAgo: 1)])
        world.activity.draft = AuditFilter()
        #expect(world.activity.apply())
        await Self.settled(world, 3)
        #expect(world.activity.emptyText == nil)
        world.activity.pane = .subscriptions
        #expect(world.activity.emptyText == "None of the 1 event read is one of this view's types.")
        world.activity.pane = .audit
        world.activity.search = "nothing like it"
        #expect(world.activity.emptyText == "No event shown matches \"nothing like it\".")
        world.activity.search = "added"
        #expect(world.activity.shown.count == 1 && world.activity.emptyText == nil)
    }

    // MARK: the views

    /// Reports' three views and the other types split the one read: every typed event is in exactly one pane, a type this
    /// version doesn't know is in Other types and said, an event with no type is only in Audit and said, and each pane's
    /// counts are `AuditDigest`'s over the read.
    @Test func theViewsSplitTheReadAndDropNothing() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([
            Self.event("l1", hoursAgo: 1), Self.event("l2", hoursAgo: 2, type: "DEVICE_ASSIGNED_TO_SERVER"),
            Self.event("l3", hoursAgo: 3, type: "DEVICE_ASSIGNED_TO_SERVER"), Self.event("s1", hoursAgo: 4, type: "SUBSCRIPTION_CREATED"),
            Self.event("s2", hoursAgo: 5, type: "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED"), Self.event("x1", hoursAgo: 6, type: "API_ACCOUNT_KEY_REVOKED"),
            Self.event("o1", hoursAgo: 7, type: "CONFIG_SETTINGS_UPDATED"), Self.event("u1", hoursAgo: 8, type: "FUTURE_TYPE"),
            Self.event("u2", hoursAgo: 9, type: "FUTURE_TYPE"), Self.event("u3", hoursAgo: 10, type: "ANOTHER_NEW_TYPE"),
            Self.event("n1", hoursAgo: 11, extra: ["type": .null]), Self.event("n2", hoursAgo: 12, extra: ["type": .number("7")]),
        ])
        world.activity.load()
        await Self.settled(world, 1)
        let model = world.activity
        func ids(_ pane: ActivityPane) -> Set<String> {
            model.pane = pane
            return Set(model.shown.map(\.event.id))
        }
        #expect(ids(.audit).count == 12)
        #expect(ids(.deviceLifecycle) == ["l1", "l2", "l3"])
        #expect(ids(.subscriptions) == ["s1", "s2"])
        #expect(ids(.accessAndSecurity) == ["x1"])
        #expect(ids(.other) == ["o1", "u1", "u2", "u3"])
        let placed = [ActivityPane.subscriptions, .deviceLifecycle, .accessAndSecurity, .other].map { ids($0).count }.reduce(0, +)
        #expect(placed + 2 == ids(.audit).count, "an event was dropped or shown twice")
        #expect(model.rows.filter { $0.pane == nil }.map(\.event.id).sorted() == ["n1", "n2"])
        #expect(model.unplacedNote == "Types this version doesn't know, shown raw under Other types: FUTURE_TYPE (2), ANOTHER_NEW_TYPE (1). 2 events have no type: only Audit lists them.")
        // The counts are the digest's.
        let events = model.rows.map(\.event.resource)
        #expect(model.counts(.deviceLifecycle) == AuditDigest(events, view: .deviceLifecycle).counts)
        #expect(model.counts(.deviceLifecycle)?.map(\.name) == ["DEVICE_ASSIGNED_TO_SERVER", "DEVICE_ADDED_TO_ORG"])
        #expect(model.counts(.deviceLifecycle)?.map(\.count) == [2, 1])
        #expect(model.counts(.other) == AuditDigest(events, types: AuditView.otherTypes + ["FUTURE_TYPE", "ANOTHER_NEW_TYPE"]).counts)
        #expect(model.counts(.other)?.map(\.count) == [2, 1, 1])
        #expect(model.counts(.audit) == nil && model.countsText(.audit) == nil)
        #expect(model.countsText(.deviceLifecycle) == "Device assigned to server 2 · Device added to org 1")
        #expect(model.countsText(.other) == "FUTURE_TYPE 2 · Config settings updated 1 · ANOTHER_NEW_TYPE 1")
        #expect(model.summary(for: .deviceLifecycle) == "3 of the 12 events in this range.")
        #expect(model.summary(for: .audit) == "12 events in this range.")
        // The row's words: a known type by name, an unknown one raw.
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.event.id, $0) })
        #expect(rows["l2"]?.type == "Device assigned to server" && rows["u1"]?.type == "FUTURE_TYPE" && rows["n1"]?.type == "—")
        #expect(rows["l1"]?.category == "Device inventory" && rows["l1"]?.outcome == "Success" && rows["l1"]?.actor == "Key A1" && rows["l1"]?.subject == "S1")
    }

    /// Every type Apple documents is offered once in the type filter, grouped by the pane that shows it.
    @Test func theTypeChoicesAreEveryKnownTypeOnce() {
        let types = ActivityModel.typeChoices.flatMap(\.types)
        #expect(types.count == AuditEventType.allCases.count && Set(types) == Set(AuditEventType.allCases))
        #expect(ActivityModel.typeChoices.map(\.pane) == [.subscriptions, .deviceLifecycle, .accessAndSecurity, .other])
        #expect(ActivityModel.typeChoices.first { $0.pane == .deviceLifecycle }?.types == AuditView.deviceLifecycle.eventTypes)
    }

    /// Apple's values in words: a type by name, its acronyms kept; anything this version doesn't know as Apple sent it.
    @Test func applesValuesReadAsWords() {
        #expect(ActivityRow.words("DEVICE_ASSIGNED_TO_SERVER", known: true) == "Device assigned to server")
        #expect(ActivityRow.words("SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED", known: true) == "iCloud storage purchase added")
        #expect(ActivityRow.words("SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED", known: true) == "AppleCare purchase removed")
        #expect(ActivityRow.words("API_ACCOUNT_KEY_REVOKED", known: true) == "API account key revoked")
        #expect(ActivityRow.words("IDP_ACCOUNT_SYNC_ENABLED", known: true) == "IdP account sync enabled")
        #expect(ActivityRow.words("DEVICE_INVENTORY", known: true) == "Device inventory")
        #expect(ActivityRow.words("FUTURE_TYPE", known: false) == "FUTURE_TYPE")
        #expect(ActivityRow.words(nil, known: false) == "—")
        #expect(ActivityModel.title(of: .accountPasswordChanged) == "Account password changed")
    }

    /// The demo org's events (`DemoAudit`), as the demo serves them: sixty over the last 30 days across at least twenty
    /// types, every pane holding some, lifecycle events naming the demo fleet's serials, two payloads Apple named by their
    /// object's spelling, said as payload problems, and one type no version knows, in Other types and said.
    @Test func theDemoOrgsEventsFillEveryPane() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add(DemoAudit.events(now: Date()))
        world.activity.draft.days = 30
        #expect(world.activity.apply())
        await Self.settled(world, 1)
        let model = world.activity, rows = model.rows
        #expect(rows.count == 60 && Set(rows.map(\.event.id)).count == 60)
        #expect(Set(rows.compactMap(\.event.type?.rawValue)).count >= 20)
        for pane in ActivityPane.allCases {
            model.pane = pane
            #expect(!model.shown.isEmpty, "\(pane) is empty")
        }
        let serials = Set(DemoFleet.make().devices.map(\.id))
        let lifecycle = rows.filter { $0.pane == .deviceLifecycle }
        #expect(lifecycle.count >= 20)
        #expect(lifecycle.filter { serials.contains($0.event.subjectID ?? "") }.count == lifecycle.count - 2, "two released devices are TEST serials")
        #expect(lifecycle.filter { ($0.event.subjectID ?? "").hasPrefix("TEST") }.count == 2)
        #expect(rows.filter { !$0.event.payloadProblems.isEmpty }.map(\.event.type?.rawValue)
                == ["SUBJECT_HAS_APPLECARE_PURCHASE_ADDED", "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED"])
        #expect(rows.filter { !$0.event.payloadProblems.isEmpty }.allSatisfy { $0.event.payload?.subscriptionID != nil }, "the payload was still read")
        #expect(model.unplacedNote == "Types this version doesn't know, shown raw under Other types: DEMO_TYPE_NOT_YET_DOCUMENTED (1).")
        // Every other payload is where Apple's attribute keys put it, and reads no field its type lacks.
        for row in rows where row.event.payloadProblems.isEmpty && row.event.type?.known != nil {
            #expect(row.event.payload?.key == row.event.type?.known?.payload.key, "\(row.event.id)")
            #expect(row.event.payload?.unreadFields.isEmpty == true && row.event.unreadAttributes.isEmpty, "\(row.event.id)")
        }
        // The default range shows the last week's part of it, and the first device in the table has a timeline.
        let first = try #require(DemoFleet.make().devices.map(\.id).sorted().first)
        #expect(lifecycle.filter { $0.event.subjectID == first }.count == 2)
        world.activity.draft = AuditFilter()
        #expect(world.activity.apply())
        await Self.settled(world, 2)
        #expect((15..<40).contains(model.rows.count), "\(model.rows.count) events in the last 7 days")
    }

    // MARK: export

    /// The CSV holds the common attributes of what the pane shows, and no payload (`ExportPolicy.auditEvents`).
    @Test func theCSVHoldsTheCommonAttributesOfWhatIsShown() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([
            Self.event("l1", hoursAgo: 1, extra: ["eventDataPropertyKey": .string("eventDataDeviceAddedToOrg"),
                                                  "eventDataDeviceAddedToOrg": .object(["serialNumber": .string("PAYLOAD-CANARY")])]),
            Self.event("s1", hoursAgo: 2, type: "SUBSCRIPTION_CREATED"),
        ])
        world.activity.load()
        await Self.settled(world, 1)
        let csv = world.activity.csv()
        #expect(csv.hasPrefix("id,eventDateTime,type,category,actorType,actorId,actorName,subjectType,subjectId,subjectName,outcome,groupId,eventDataPropertyKey\r\n"))
        #expect(csv.contains("l1,") && csv.contains("s1,") && !csv.contains("PAYLOAD-CANARY"))
        world.activity.pane = .subscriptions
        #expect(world.activity.csv().contains("s1,") && !world.activity.csv().contains("l1,"))
        #expect(world.activity.exportName == "audit-subscriptions.csv")
        world.activity.pane = .audit
        #expect(world.activity.exportName == "audit-events.csv")
    }

    /// A URL in an event's subject or actor name, or anywhere in its payload, shows only where it goes, with its tag: in the
    /// row, the inspector's every field and the CSV (the contract-2.8 review's M2: the names went raw to the screen and
    /// the CSV; M4: two URLs on one host showed alike).
    @Test func aURLInAnEventShowsOnlyWhereItGoes() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([Self.event("w1", hoursAgo: 1, type: "WEBHOOK_UPDATED", extra: [
            "subjectName": .string("https://hooks.example.com/T0/CANARYSUBJECT"), "actorName": .string("Key via https://CANARYACTOR:pw@hooks.example.com/x"),
            "eventDataWebhookUpdated": .object(["url": .string("https://hooks.example.com/T0/CANARYPAYLOAD"),
                                                "previous": .object(["target": .string("https://hooks.example.com/T0/CANARYOLD")])]),
            "eventDataFuture": .string("now https://hooks.example.com/CANARYOTHER"),
        ])])
        world.activity.load()
        await Self.settled(world, 1)
        let row = try #require(world.activity.rows.first)
        #expect(row.subject == "https://hooks.example.com/… (tag \(WebhookURL.tag("https://hooks.example.com/T0/CANARYSUBJECT")))")
        let payload = try #require(row.event.payload)
        #expect(payload.object["url"] == .string(WebhookURL.shown("https://hooks.example.com/T0/CANARYPAYLOAD")))
        #expect(payload.object["url"] != payload.object["previous"]?["target"], "a repointed webhook shows as another tag")
        let detail = AuditEventDetail(row.event)
        let shown = detail.common.map { row.event.attributes[$0.key]?.jsonText ?? "" } + detail.payloadFields.map { payload.object[$0.key]?.jsonText ?? "" }
            + detail.otherAttributes.map { row.event.attributes[$0]?.jsonText ?? "" } + [row.subject, row.actor, row.byline, world.activity.csv()]
        #expect(detail.otherAttributes == ["eventDataFuture"])
        for text in shown { #expect(!text.contains("CANARY"), "\(text)") }
        #expect(world.activity.csv().contains("https://hooks.example.com/… (tag "))
    }

    // MARK: the inspector

    /// The detail labels the common attributes, reads the payload where Apple put it, and says each payload problem.
    @Test func theDetailSaysThePayloadAndItsProblems() throws {
        // Named by its object's spelling (`Icloud`), found under the type's key (Phase 2a review M1).
        let icloud = AuditEvent(resource: Self.event("e1", hoursAgo: 1, type: "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED", extra: [
            "eventDataPropertyKey": .string("eventDataSubjectHasIcloudStoragePurchaseAdded"),
            "eventDataSubjectHasICloudStoragePurchaseAdded": .object(["subscriptionId": .string("SUB1"), "seats": .number("5")]),
            "newAttribute": .string("x"),
        ]))
        let detail = AuditEventDetail(icloud)
        #expect(detail.common.map(\.key) == AuditEvent.fields)
        #expect(detail.common.map(\.label).prefix(3) == ["When", "Type", "Category"])
        #expect(detail.payloadKey == "eventDataSubjectHasICloudStoragePurchaseAdded")
        #expect(detail.payloadFields.map(\.key) == ["subscriptionId", "seats"])
        #expect(detail.payloadFields.map(\.label) == ["subscriptionId", "seats (not in Apple's docs)"])
        #expect(detail.notes == ["Apple named the payload eventDataSubjectHasIcloudStoragePurchaseAdded, which the event doesn't have. It was read under the type's own key, eventDataSubjectHasICloudStoragePurchaseAdded."])
        #expect(detail.otherAttributes == ["newAttribute"])
        #expect(detail.pane == "Subscriptions & Purchases")

        let notObject = AuditEventDetail(AuditEvent(resource: Self.event("e2", hoursAgo: 1, extra: [
            "eventDataPropertyKey": .string(""), "eventDataDeviceAddedToOrg": .string("not an object"),
        ])))
        #expect(notObject.payloadKey == nil && notObject.payloadFields.isEmpty)
        #expect(notObject.notes == ["Apple named the payload with an empty key.", "The payload isn't an object, so its fields can't be read."])

        let unknown = AuditEventDetail(AuditEvent(resource: Self.event("e3", hoursAgo: 1, type: "FUTURE_TYPE", extra: [
            "eventDataPropertyKey": .string("eventDataFutureType"), "eventDataFutureType": .object(["b": .string("2"), "a": .string("1")]),
        ])))
        #expect(unknown.payloadKey == "eventDataFutureType" && unknown.payloadFields.map(\.label) == ["b", "a"])
        #expect(unknown.notes == ["This version doesn't know the type FUTURE_TYPE: the event and its payload are shown as Apple sent them, under Other types."])
        #expect(unknown.pane == "Other types")

        let none = AuditEventDetail(AuditEvent(resource: Self.event("e4", hoursAgo: 1)))
        #expect(none.notes == ["Apple sent no payload."] && none.payloadKey == nil)

        let fieldless = AuditEventDetail(AuditEvent(resource: Self.event("e5", hoursAgo: 1, type: "DEVICE_IS_ERASED", extra: [
            "eventDataPropertyKey": .string("eventDataDeviceIsErased"), "eventDataDeviceIsErased": .object(["serialNumber": .string("X")]),
        ])))
        #expect(fieldless.notes == ["Apple documents no fields for Device is erased: what came is shown as sent."])
        #expect(fieldless.payloadFields.map(\.label) == ["serialNumber (not in Apple's docs)"])

        let untyped = AuditEventDetail(AuditEvent(resource: Self.event("e6", hoursAgo: 1, extra: ["type": .null])))
        #expect(untyped.notes.first == "The event has no type: only Audit lists it, and its payload can't be found by type.")
        #expect(untyped.pane == "Audit only")
    }
}

/// Device 360's ABM timeline: the device's events by Apple's `filter[subjectId]`, its own panel.
@MainActor
@Suite("Device timeline", .serialized)
struct DeviceTimelineTests {
    static func settled(_ world: World, _ reads: Int) async {
        await eventually("\(reads) timeline reads, \(world.detail.timelineReadsFinished) so far") { world.detail.timelineReadsFinished >= reads }
    }

    @Test func theTimelineIsTheDevicesEventsNewestFirst() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([
            ActivityTests.event("t2", hoursAgo: 48, subject: "ADEV0000001"), ActivityTests.event("t1", hoursAgo: 2, type: "DEVICE_ASSIGNED_TO_SERVER", subject: "ADEV0000001"),
            ActivityTests.event("x", hoursAgo: 1, subject: "ADEV0000002"), ActivityTests.event("old", hoursAgo: 24 * 31, subject: "ADEV0000001"),
        ])
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        guard case .loaded(.read(let rows, let truncated)) = world.detail.timeline else { Issue.record("\(world.detail.timeline)"); return }
        #expect(rows.map(\.event.id) == ["t1", "t2"] && !truncated)
        #expect(DeviceTimeline.read(rows: rows, truncated: false).note == nil)
        let sent = try #require(ActivityTests.audit(world).last)
        #expect(sent.contains("filter%5BsubjectId%5D=ADEV0000001"), "\(sent)")
        let query = try #require(world.detail.timelineQuery)
        #expect(query.end.timeIntervalSince(query.start) == Double(DeviceDetailModel.timelineDays) * 86_400 && DeviceDetailModel.timelineDays == 30)
    }

    /// Phase 2b review L5 (mutant T2): a timeline the page cap cut says so, "showing N events: the list stopped at the page
    /// limit", never as if every event naming the device were there.
    @Test func aTimelineCutAtThePageCapSaysSo() async throws {
        let world = try await World.make(pageCap: 1)
        world.stubs["a"]!.add((0..<1_001).map { ActivityTests.event("t\($0)", hoursAgo: 1 + Double($0) / 100, subject: "ADEV0000001") })
        world.stubs["a"]!.add([ActivityTests.event("other", hoursAgo: 1, subject: "ADEV0000002")])
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        guard case .loaded(let timeline) = world.detail.timeline, case .read(let rows, let truncated) = timeline else {
            Issue.record("\(world.detail.timeline)")
            return
        }
        #expect(truncated && rows.count == 1_000, "\(rows.count) rows, truncated \(truncated)")
        #expect(timeline.note == "Showing \(1_000.formatted()) events: the list stopped at the page limit.")
        #expect(ActivityTests.audit(world).count == 1, "the cap is one page: \(ActivityTests.audit(world))")
    }

    @Test func aTimelineSaysWhatItLacks() {
        #expect(DeviceTimeline.read(rows: [], truncated: false).note == "No audit event names this device in the last 30 days.")
        #expect(DeviceTimeline.notInScope("why").note == "why")
        let row = ActivityRow(AuditEvent(resource: ActivityTests.event("e", hoursAgo: 1)), id: 0)
        #expect(DeviceTimeline.read(rows: [row], truncated: true).note == "Showing 1 event: the list stopped at the page limit.")
        #expect(row.byline == "by Key A1" && !row.failed)
        let failed = ActivityRow(AuditEvent(resource: ActivityTests.event("f", hoursAgo: 1, extra: ["outcome": .string("FAILURE")])), id: 1)
        #expect(failed.byline == "by Key A1, failed" && failed.failed && failed.outcome == "Failure")
    }

    /// A role that can't read the audit log: the timeline says so, and only the timeline.
    @Test func aForbiddenTimelineSaysSoInItsPanelOnly() async throws {
        let world = try await World.make()
        world.stubs["a"]!.forbid("/v1/auditEvents")
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        await eventually("four panels read") { world.detail.readsFinished == 4 }
        if case .forbidden = world.detail.timeline {} else { Issue.record("timeline: \(world.detail.timeline)") }
        if case .loaded = world.detail.device {} else { Issue.record("device: \(world.detail.device)") }
        if case .loaded = world.detail.coverage {} else { Issue.record("AppleCare: \(world.detail.coverage)") }
    }

    /// A read that fails says why in the timeline.
    @Test func aFailedTimelineSaysWhy() async throws {
        let world = try await World.make()
        world.stubs["a"]!.queue(500, for: "/v1/auditEvents")
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        if case .failed(let why) = world.detail.timeline { #expect(why == "Apple's service failed (HTTP 500). Try again later.") }
        else { Issue.record("\(world.detail.timeline)") }
    }

    /// Apple School Manager has no audit log: the timeline says so, in words, and nothing is sent for it.
    @Test func aSchoolOrgsTimelineIsNotInScope() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        guard case .loaded(.notInScope(let why)) = world.detail.timeline else { Issue.record("\(world.detail.timeline)"); return }
        #expect(why == "Apple School Manager's API has no audit events to read.")
        #expect(ActivityTests.audit(world).isEmpty)
    }

    /// A serial the audit filter can't take is never sent, and said.
    @Test func aSerialThatCantBeAskedIsSaid() async throws {
        let world = try await World.make()
        world.detail.show("A DEV/1")
        await Self.settled(world, 1)
        if case .failed(let why) = world.detail.timeline { #expect(why == "This serial can't be asked of the audit log.") }
        else { Issue.record("\(world.detail.timeline)") }
        #expect(ActivityTests.audit(world).isEmpty)
    }

    /// An org switch empties a timeline already read, and an org that can't be used says why there, never a spinner.
    @Test func anOrgSwitchEmptiesTheTimelineAndAnUnusableOrgSaysWhy() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([ActivityTests.event("t1", hoursAgo: 2, subject: "ADEV0000001")])
        world.detail.show("ADEV0000001")
        await Self.settled(world, 1)
        guard case .loaded(.read(let rows, _)) = world.detail.timeline, rows.count == 1 else { Issue.record("\(world.detail.timeline)"); return }
        world.orgs.select("b")
        if case .loading = world.detail.timeline {} else { Issue.record("org a's timeline stayed after the switch: \(world.detail.timeline)") }
        #expect(world.detail.timelineQuery == nil)

        let unusable = try await World.make(profiles: [World.unusable])
        unusable.detail.show("ADEV0000001")
        if case .failed(let why) = unusable.detail.timeline { #expect(why.contains("can't be used")) } else { Issue.record("a spinner that can't end") }
    }

    /// The device's timeline read, in flight at an org switch or at another device's selection, lands nowhere.
    @Test func aSupersededTimelineLandsNowhere() async throws {
        let world = try await World.make()
        world.stubs["a"]!.add([ActivityTests.event("t1", hoursAgo: 2, subject: "ADEV0000001")])
        let gate = world.gates["a"]!
        gate.hold("audit", ActivityTests.auditPages)
        world.detail.show("ADEV0000001")
        await eventually("the timeline held") { gate.held == 1 }
        world.orgs.select("b")
        gate.release("audit")
        await Self.settled(world, 1)
        if case .loading = world.detail.timeline {} else { Issue.record("org a's timeline landed after the switch: \(world.detail.timeline)") }

        gate.hold("audit", ActivityTests.auditPages)
        world.orgs.select("a")
        world.detail.show("ADEV0000001")
        await eventually("the timeline held again") { gate.held == 1 }
        world.detail.show("ADEV0000002")
        gate.release("audit")
        await Self.settled(world, 3)
        guard case .loaded(.read(let rows, _)) = world.detail.timeline else { Issue.record("\(world.detail.timeline)"); return }
        #expect(rows.isEmpty, "ADEV0000001's events landed on ADEV0000002")
    }
}
