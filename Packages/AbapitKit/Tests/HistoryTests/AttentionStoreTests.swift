import Foundation
import Orgs
import Testing
@testable import History

/// "Needs attention" keeps only what can't be read again: when a finding first appeared, and whether it was dismissed or
/// snoozed (plan §8.0). The table is version 2 of the history file, so the migration must leave every snapshot as it was.
@Suite("Attention store")
struct AttentionStoreTests {
    static let day: TimeInterval = 86_400
    static let acme = Scratch.apple("acme"), other = Scratch.apple("other-org")

    static func store() throws -> SnapshotStore { try SnapshotStore(storage: .memory, appVersion: "1") }

    // MARK: migration

    /// A version-1 file with snapshots and items (written the way a store at version 1 wrote them), then opened by this one:
    /// every row of `snapshots` and `items` is byte-identical, the version is 2, the table is there and empty, the mode held.
    @Test func aVersionOneFileMigratesAndKeepsEverySnapshotByteIdentical() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        do {
            let file = try Scratch.open(path)
            try file.execute(Schema.toVersion1)
            try file.execute("""
                INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes, counts) \
                VALUES ('2026-01-01T00:00:00Z', 'BUSINESSAPI.x', 'Example', 'business', 'swiftabapit 1', '{"a": "b"}', 'acme', '{}', '{"devices": 2}');
                INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes, counts) \
                VALUES ('2026-01-02T00:00:00Z', '', 'Other', 'mosyle', 'swiftabapit 1', '{}', 'other', '{"x": "y"}', '{}');
                INSERT INTO items VALUES (1, 'devices', 'SERIAL0001', '{"deviceModel": "Mac"}');
                INSERT INTO items VALUES (1, 'devices', 'SERIAL0002', '{"deviceModel": "\\u00e9"}');
                INSERT INTO items VALUES (2, 'people', 'p1', '{}');
                """)
            #expect(try file.userVersion() == 1)
        }
        let dump = {
            let file = try Scratch.open(path)
            let snapshots = try file.rows("SELECT * FROM snapshots ORDER BY id") { row in
                try (0..<10).map { try row.text(Int32($0)) ?? "NULL" }.joined(separator: "|")
            }
            let items = try file.rows("SELECT * FROM items ORDER BY snapshot_id, resource, item_id") { row in
                try (0..<4).map { try row.text(Int32($0)) ?? "NULL" }.joined(separator: "|")
            }
            return snapshots + items
        }
        let before = try dump()
        #expect(before.count == 5)

        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readWrite)
        #expect(try dump() == before)
        let file = try Scratch.open(path)
        #expect(try file.userVersion() == 2)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM attention") == 0)
        #expect(Scratch.mode(path) == 0o600)
        #expect(Scratch.mode(Scratch.path(folder)) == 0o700)
        // The migrated file works as a new one does, and is not migrated again.
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["SERIAL0001"], at: Scratch.noon)
        #expect(try await store.snapshots(org: Self.acme).count == 1)
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(try Scratch.count(Scratch.open(path), "SELECT COUNT(*) FROM attention") == 1)
    }

    /// The migration keeps the file's other guarantees: a version-1 file wider than `0600` is narrowed, a link is refused.
    @Test func theMigrationKeepsTheFileSafety() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]))
        try Scratch.open(path).execute(Schema.toVersion1)
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(Scratch.mode(path) == 0o600)

        let linked = root.appending(path: "linked")
        let target = Scratch.path(root.appending(path: "target.sqlite"))
        #expect(FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600]))
        try Scratch.open(target).execute(Schema.toVersion1)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let linkPath = Scratch.path(linked.appending(path: "history.sqlite"))
        #expect(symlink(target, linkPath) == 0)
        #expect(throws: SnapshotStore.Failure.link(path: linkPath)) { _ = try SnapshotStore(storage: .folder(linked), appVersion: "1") }
        #expect(try Scratch.open(target).userVersion() == 1)
    }

    /// A foreign file can carry `user_version` 1: refused before any write, bytes and mode unchanged.
    @Test func aForeignFileAtVersionOneIsRefusedAndLeftAsItIs() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]))
        do {
            let file = try Scratch.open(path)
            try file.execute("CREATE TABLE snapshots (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO snapshots VALUES (1, 'x'); PRAGMA user_version = 1;")
        }
        let before = try Data(contentsOf: URL(filePath: path))
        #expect(throws: SnapshotStore.Failure.notThisAppsFile(path: path)) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
        #expect(try Data(contentsOf: URL(filePath: path)) == before)
        #expect(Scratch.mode(path) == 0o644)
        let file = try Scratch.open(path)
        #expect(try file.userVersion() == 1)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'attention'") == 0)
    }

    /// Two stores open one version-1 file: the second gets in between the first's reading the version and taking the write
    /// lock (the hook). The first reads the version again under the lock, finds 2, and doesn't migrate twice (which would
    /// fail: the table exists).
    @Test func twoStoresOpeningAVersionOneFileMigrateItOnce() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        try Scratch.open(path).execute(Schema.toVersion1)
        let steps = Shared<[String]>([]), second = Unchecked<SnapshotStore?>(nil)
        let first = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(SnapshotStore.Failure) in
            switch step {
            case .foundVersion1:
                steps.set(steps.value + ["found"])
                second.value = try SnapshotStore(storage: .folder(folder), appVersion: "1") { inner throws(SnapshotStore.Failure) in
                    if case .migrating = inner { steps.set(steps.value + ["second migrates"]) }
                }
            case .migrating:
                steps.set(steps.value + ["first migrates"])
            default:
                break
            }
        }
        #expect(steps.value == ["found", "second migrates"])
        #expect(first.access == .readWrite)
        try await second.value?.seen(org: Self.acme, rule: "r", subjects: ["A"], at: Scratch.noon)
        #expect(try await first.state(org: Self.acme).map(\.subject) == ["A"])
        #expect(try Scratch.open(path).userVersion() == 2)
    }

    // MARK: first seen

    @Test func firstSeenIsRecordedOnceAndNeverOverwritten() async throws {
        let store = try Self.store()
        let first = Scratch.noon
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["A", "B"], at: first)
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["A", "B", "C"], at: first.addingTimeInterval(5 * Self.day))
        // An earlier clock reading doesn't rewrite it either, and doesn't move last_seen back.
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["A"], at: first.addingTimeInterval(-3 * Self.day))
        let state = try await store.state(org: Self.acme)
        #expect(state.map(\.subject) == ["A", "B", "C"])
        #expect(state.map(\.firstSeen) == [first, first, first.addingTimeInterval(5 * Self.day)])
        #expect(state.map(\.lastSeen) == [first.addingTimeInterval(5 * Self.day), first.addingTimeInterval(5 * Self.day), first.addingTimeInterval(5 * Self.day)])
        #expect(state.allSatisfy { $0.dismissedAt == nil && $0.snoozedUntil == nil && !$0.isHidden(at: first) })
    }

    @Test func aRuleAndASubjectAreNeverEmpty() async throws {
        let store = try Self.store()
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "", subjects: ["A"], at: Scratch.noon) }
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "r", subjects: [""], at: Scratch.noon) }
        for name in ["Jane Example's MacBook Pro", "a b", "a/b", "a\"b", "a\u{0}b", String(repeating: "x", count: 129)] {
            await #expect(throws: SnapshotStore.Failure.notAnIdentifier, "\(name)") {
                try await store.seen(org: Self.acme, rule: "r", subjects: [name], at: Scratch.noon)
            }
        }
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "a rule", subjects: [], at: Scratch.noon) }
        // One bad subject stores none of the run's.
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "r", subjects: ["OK1", "bad name"], at: Scratch.noon) }
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["C02XX0000001", "0b3a1c52-0000-4000-8000-000000000001", "12345"], at: Scratch.noon)
        #expect(try await store.state(org: Self.acme).count == 3)
    }

    /// Format characters are refused (a direction override, a joiner, a zero-width space: each would make two ids look alike);
    /// "e with acute" precomposed and decomposed are both identifiers, and two; and the limits hold in bytes too (four a
    /// character), so one character carrying thousands of combining marks is refused.
    @Test func identifiersRefuseFormatCharactersAndAreBoundedInBytes() async throws {
        let store = try Self.store()
        for name in ["a\u{202E}b", "a\u{200D}b", "a\u{200B}b"] {
            #expect(!SnapshotStore.isIdentifier(name, limit: 128), "\(Array(name.unicodeScalars))")
            await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "r", subjects: [name], at: Scratch.noon) }
            await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: name, subjects: [], at: Scratch.noon) }
        }
        let precomposed = "\u{E9}", decomposed = "e\u{301}"
        #expect(SnapshotStore.isIdentifier(precomposed, limit: 128) && SnapshotStore.isIdentifier(decomposed, limit: 128))
        try await store.seen(org: Self.acme, rule: "r", subjects: [precomposed, decomposed], at: Scratch.noon)
        #expect(Set(try await store.state(org: Self.acme).map { Array($0.subject.utf8) }) == [Array(precomposed.utf8), Array(decomposed.utf8)])

        let marked = "e" + String(repeating: "\u{301}", count: 5000)
        #expect(marked.count == 1 && marked.utf8.count == 10_001)
        #expect(!SnapshotStore.isIdentifier(marked, limit: 128) && !SnapshotStore.isIdentifier(marked, limit: 64))
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: "r", subjects: [marked], at: Scratch.noon) }
        await #expect(throws: SnapshotStore.Failure.notAnIdentifier) { try await store.seen(org: Self.acme, rule: marked, subjects: [], at: Scratch.noon) }

        // At the edge: 128 characters of four bytes are 512 bytes and pass; 128 characters of 513 bytes don't.
        let widest = String(repeating: "\u{10000}", count: 128)
        #expect(widest.count == 128 && widest.utf8.count == 512 && SnapshotStore.isIdentifier(widest, limit: 128))
        let justUnder = String(repeating: "\u{10000}", count: 127) + "e\u{301}"
        #expect(justUnder.count == 128 && justUnder.utf8.count == 511 && SnapshotStore.isIdentifier(justUnder, limit: 128))
        let over = justUnder + "\u{301}"
        #expect(over.count == 128 && over.utf8.count == 513 && !SnapshotStore.isIdentifier(over, limit: 128))
        #expect(!SnapshotStore.isIdentifier(String(repeating: "x", count: 65), limit: 64) && SnapshotStore.isIdentifier(String(repeating: "x", count: 64), limit: 64))
    }

    /// Canonically equivalent strings are two rows: the table keys by bytes, and a `Set<String>` would have merged them.
    @Test func unicodeEquivalentSubjectsStayTwoRows() async throws {
        let store = try Self.store()
        let precomposed = "caf\u{E9}", decomposed = "cafe\u{301}"
        #expect(precomposed == decomposed && Array(precomposed.utf8) != Array(decomposed.utf8))
        try await store.seen(org: Self.acme, rule: "r", subjects: [precomposed, decomposed, precomposed], at: Scratch.noon)
        let state = try await store.state(org: Self.acme)
        #expect(state.count == 2)
        #expect(Set(state.map { Array($0.subject.utf8) }) == [Array(precomposed.utf8), Array(decomposed.utf8)])
    }

    // MARK: dismiss and snooze

    @Test func aDismissalHoldsAndKeepsFirstSeen() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["A", "B"], at: t)
        try await store.dismiss(org: Self.acme, rule: "check_in", subject: "A", at: t.addingTimeInterval(Self.day))
        try await store.seen(org: Self.acme, rule: "check_in", subjects: ["A", "B"], at: t.addingTimeInterval(10 * Self.day))
        let state = try await store.state(org: Self.acme)
        #expect(state[0].subject == "A" && state[0].dismissedAt == t.addingTimeInterval(Self.day) && state[0].firstSeen == t)
        #expect(state[0].isHidden(at: t.addingTimeInterval(20 * Self.day)))
        #expect(!state[1].isHidden(at: t))
    }

    @Test func aSnoozeHidesUntilItsDateThenShowsAgainWithTheOriginalFirstSeen() async throws {
        let store = try Self.store()
        let t = Scratch.noon, until = t.addingTimeInterval(7 * Self.day)
        try await store.seen(org: Self.acme, rule: "quiet_service", subjects: ["S1"], at: t)
        try await store.snooze(org: Self.acme, rule: "quiet_service", subject: "S1", until: until)
        try await store.seen(org: Self.acme, rule: "quiet_service", subjects: ["S1"], at: t.addingTimeInterval(8 * Self.day))
        let finding = try #require(try await store.state(org: Self.acme).first)
        #expect(finding.snoozedUntil == until && finding.firstSeen == t)
        #expect(finding.isHidden(at: until.addingTimeInterval(-1)))
        #expect(!finding.isHidden(at: until))
    }

    @Test func theLatestChoiceWins() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: t)
        try await store.snooze(org: Self.acme, rule: "r", subject: "A", until: t.addingTimeInterval(Self.day))
        try await store.dismiss(org: Self.acme, rule: "r", subject: "A", at: t)
        var finding = try #require(try await store.state(org: Self.acme).first)
        #expect(finding.dismissedAt == t && finding.snoozedUntil == nil)
        try await store.snooze(org: Self.acme, rule: "r", subject: "A", until: t.addingTimeInterval(Self.day))
        finding = try #require(try await store.state(org: Self.acme).first)
        #expect(finding.dismissedAt == nil && finding.snoozedUntil == t.addingTimeInterval(Self.day))
    }

    @Test func aFindingNeverSeenCantBeDismissedOrSnoozed() async throws {
        let store = try Self.store()
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: Scratch.noon)
        await #expect(throws: SnapshotStore.Failure.noFinding(rule: "r", subject: "Z")) {
            try await store.dismiss(org: Self.acme, rule: "r", subject: "Z", at: Scratch.noon)
        }
        await #expect(throws: SnapshotStore.Failure.noFinding(rule: "other", subject: "A")) {
            try await store.snooze(org: Self.acme, rule: "other", subject: "A", until: Scratch.noon)
        }
        // Another org's finding isn't this org's to change.
        await #expect(throws: SnapshotStore.Failure.noFinding(rule: "r", subject: "A")) {
            try await store.dismiss(org: Self.other, rule: "r", subject: "A", at: Scratch.noon)
        }
        #expect(try await store.state(org: Self.acme).allSatisfy { $0.dismissedAt == nil })
    }

    // MARK: forgetting

    /// A finding not seen for 30 days is deleted with its dismissal; one seen again inside the 30 days keeps both; one that
    /// comes back after is new.
    @Test func aFindingNotSeenFor30DaysIsDeletedDismissalAndAll() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        try await store.seen(org: Self.acme, rule: "r", subjects: ["gone", "blip", "stays"], at: t)
        try await store.dismiss(org: Self.acme, rule: "r", subject: "gone", at: t)
        try await store.dismiss(org: Self.acme, rule: "r", subject: "blip", at: t)
        // A run that missed `blip` (a failed read) 29 days on: nothing is forgotten yet.
        try await store.seen(org: Self.acme, rule: "r", subjects: ["stays"], at: t.addingTimeInterval(29 * Self.day))
        #expect(try await store.state(org: Self.acme).map(\.subject) == ["blip", "gone", "stays"])
        // `blip` is back on day 30 (`gone` is exactly 30 days unseen, still kept): its row and dismissal are as they were.
        try await store.seen(org: Self.acme, rule: "r", subjects: ["stays", "blip"], at: t.addingTimeInterval(30 * Self.day))
        var state = try await store.state(org: Self.acme)
        #expect(state.map(\.subject) == ["blip", "gone", "stays"])
        #expect(state[0].dismissedAt == t && state[0].firstSeen == t)
        // `blip` goes unseen for more than 30 days: deleted; coming back is a new finding.
        try await store.seen(org: Self.acme, rule: "r", subjects: ["stays"], at: t.addingTimeInterval(61 * Self.day))
        #expect(try await store.state(org: Self.acme).map(\.subject) == ["stays"])
        let back = t.addingTimeInterval(70 * Self.day)
        try await store.seen(org: Self.acme, rule: "r", subjects: ["stays", "blip"], at: back)
        state = try await store.state(org: Self.acme)
        #expect(state[0].subject == "blip" && state[0].firstSeen == back && state[0].dismissedAt == nil)
    }

    @Test func theCutoffIsExactlyThirtyDays() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: t)
        // Exactly 30 days unseen: kept. A second more: deleted.
        try await store.seen(org: Self.acme, rule: "r", subjects: [], at: t.addingTimeInterval(30 * Self.day))
        #expect(try await store.state(org: Self.acme).count == 1)
        try await store.seen(org: Self.acme, rule: "r", subjects: [], at: t.addingTimeInterval(30 * Self.day + 1))
        #expect(try await store.state(org: Self.acme).isEmpty)
    }

    /// Each rule ages only its own rows: a rule that wasn't run (skipped as not read, or the app idle) keeps its findings and
    /// dismissals while another rule runs.
    @Test func aRuleAgesOnlyItsOwnFindings() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        for rule in ["check_in", "quiet_service"] {
            try await store.seen(org: Self.acme, rule: rule, subjects: ["A"], at: t)
            try await store.dismiss(org: Self.acme, rule: rule, subject: "A", at: t)
        }
        // The app was idle 31 days; one rule runs first.
        try await store.seen(org: Self.acme, rule: "check_in", subjects: [], at: t.addingTimeInterval(31 * Self.day))
        var state = try await store.state(org: Self.acme)
        #expect(state.map(\.rule) == ["quiet_service"])
        #expect(state[0].dismissedAt == t && state[0].firstSeen == t)
        // A rule skipped as not read for 31 days, while another runs daily, keeps its rows.
        let skipped = t.addingTimeInterval(100 * Self.day)
        try await store.seen(org: Self.acme, rule: "migration_deadline", subjects: ["M1"], at: skipped)
        try await store.dismiss(org: Self.acme, rule: "migration_deadline", subject: "M1", at: skipped)
        for day in 1...31 { try await store.seen(org: Self.acme, rule: "check_in", subjects: ["Z"], at: skipped.addingTimeInterval(Double(day) * Self.day)) }
        state = try await store.state(org: Self.acme)
        // `quiet_service` too, idle 130 days, keeps its row: nothing ages a rule that doesn't run.
        #expect(state.map(\.rule) == ["check_in", "migration_deadline", "quiet_service"])
        #expect(state[1].dismissedAt == skipped && state[1].firstSeen == skipped)
        #expect(state[2].dismissedAt == t)
    }

    /// An org with findings and no snapshots is still taken: a new org must not inherit its dismissals.
    @Test func anOrgWithOnlyFindingsIsStillANameInUse() async throws {
        let store = try Self.store()
        try await store.record(org: Self.other, takenAt: Scratch.noon, resources: [:])
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: Scratch.noon)
        #expect(try await store.orgIDs() == ["acme", "other-org"])
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A", "B"], at: Scratch.noon)
        #expect(try await store.orgIDs() == ["acme", "other-org"])
        try await store.removeAll(org: Self.acme)
        #expect(try await store.orgIDs() == ["other-org"])
    }

    // MARK: orgs

    @Test func orgsAreKeptApart() async throws {
        let store = try Self.store()
        let t = Scratch.noon
        try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: t)
        try await store.seen(org: Self.other, rule: "r", subjects: ["A", "B"], at: t.addingTimeInterval(Self.day))
        try await store.dismiss(org: Self.acme, rule: "r", subject: "A", at: t)
        #expect(try await store.state(org: Self.acme).map(\.subject) == ["A"])
        #expect(try await store.state(org: Self.other).map(\.firstSeen) == [t.addingTimeInterval(Self.day), t.addingTimeInterval(Self.day)])
        #expect(try await store.state(org: Self.other).allSatisfy { $0.dismissedAt == nil })
        // One org's run never forgets another's findings.
        try await store.seen(org: Self.other, rule: "r", subjects: [], at: t.addingTimeInterval(90 * Self.day))
        #expect(try await store.state(org: Self.acme).count == 1)
        #expect(try await store.state(org: Self.other).isEmpty)
        // Removing an org's history removes its findings, and only its own.
        try await store.seen(org: Self.other, rule: "r", subjects: ["Z"], at: t.addingTimeInterval(90 * Self.day))
        try await store.removeAll(org: Self.acme)
        #expect(try await store.state(org: Self.acme).isEmpty)
        #expect(try await store.state(org: Self.other).map(\.subject) == ["Z"])
        await #expect(throws: SnapshotStore.Failure.noOrg) { try await store.state(org: OrgProfile(id: "", name: "x", provider: .apple)) }
    }

    @Test func aFileFromANewerVersionIsNeverWritten() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite"))).execute("PRAGMA user_version = 3")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        await #expect(throws: SnapshotStore.Failure.readOnly(version: 3)) { try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: Scratch.noon) }
        await #expect(throws: SnapshotStore.Failure.readOnly(version: 3)) { try await store.dismiss(org: Self.acme, rule: "r", subject: "A", at: Scratch.noon) }
        #expect(try await store.state(org: Self.acme).isEmpty)
    }
}
