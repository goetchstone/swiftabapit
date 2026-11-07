import AppleModels
import AppModels
import Foundation
import Testing
import TestSupport

/// The demo org's screens agree (plan §4, demo mode): each demo file names what another one holds, by the id that screen
/// reads, so a blueprint member, an audit subject or an Apple MDM device that names nothing shows as a bare id in the
/// demo and its pictures. The five units wrote their demos apart, and two named ids nobody had (the merge of Phase 2b).
/// The whole demo, as `DemoOrg.make()` loads it, through the screen models over the strict stub.
@MainActor
@Suite("The demo org's screens agree")
struct DemoTests {
    /// Org `a` with the demo org's data and nothing else, People and Content read.
    static func demo() async throws -> World {
        let world = try await World.make(devices: ["a": 0, "b": 0])
        DemoOrg.load(into: world.stubs["a"]!)
        world.people.load()
        world.content.load()
        await eventually("the people") { world.people.readsFinished >= 3 }
        await eventually("the content") { world.content.readsFinished >= 4 }
        for state in [world.people.users.state, world.people.groups.state, world.people.units.state, world.content.blueprints.state,
                      world.content.configurations.state] {
            guard case .loaded = state else { throw Unread(state: state) }
        }
        return world
    }

    struct Unread: Error { let state: LoadState }

    /// Every member of every demo blueprint is named from what the stub included: its users and user groups are
    /// `DemoPeople`'s, its devices the fleet's, its apps, packages and configurations `DemoContent`'s.
    @Test func everyBlueprintMemberNamesSomething() async throws {
        let world = try await Self.demo()
        let content = world.content
        content.kind = .blueprints
        let blueprints = content.blueprints.rows.map(\.id)
        #expect(blueprints.count == 4)
        var people = 0
        for id in blueprints {
            let before = content.detail.readsFinished
            content.selection = id
            await eventually("\(id)'s detail") { content.detail.readsFinished > before }
            guard case .loaded(let detail) = content.detail.item else {
                Issue.record("\(id): \(content.detail.item)")
                continue
            }
            #expect(detail.membersNote == nil, "\(id)")
            for group in detail.members {
                let unnamed = group.members.filter { $0.name == nil }.map(\.id)
                #expect(unnamed.isEmpty, "\(id) \(group.title) names nothing for \(unnamed)")
                if group.relationship == .users || group.relationship == .userGroups { people += group.members.count }
            }
        }
        #expect(people >= 10, "the demo's blueprints hold users and groups: \(people)")
    }

    /// Every audit event names what the demo holds: a person `DemoPeople` has (the one who left only as the id a group still
    /// keeps, so People shows them by id), a device of the fleet or one released from it (`TEST…`), `DemoContent`'s
    /// configuration, `DemoPeople`'s org unit. The actors who are people are `DemoPeople`'s users too.
    @Test func everyAuditEventNamesWhatTheDemoHolds() async throws {
        let world = try await Self.demo()
        let people = world.people
        let users = Set(people.users.rows.map(\.id)), units = Set(people.units.rows.map(\.id))
        var kept: Set<String> = []
        for group in people.groups.rows {
            people.selectedGroup = group.id
            await eventually("\(group.id)'s members") { people.groupMembers.owner == group.id && !people.groupMembers.state.isLoading }
            kept.formUnion(people.groupMembers.ids)
        }
        let serials = Set(DemoFleet.make().devices.map(\.id))
        let configurations = Set(world.content.configurations.rows.map(\.id))
        world.activity.draft.days = 30
        #expect(world.activity.apply())
        await eventually("the audit read") { world.activity.readsFinished >= 1 }
        let events = world.activity.rows.map(\.event)
        #expect(events.count == 60)
        for event in events {
            let subject = event.subjectID ?? "", what = "\(event.id) \(event.type?.rawValue ?? "")"
            switch event.subjectType?.rawValue {
            case "USER":
                if event.type?.known == .accountDeleted {
                    #expect(!users.contains(subject) && kept.contains(subject), "\(what): the one who left, kept by a group")
                } else {
                    #expect(users.contains(subject), "\(what) names no user: \(subject)")
                }
            case "DEVICE": #expect(serials.contains(subject) || subject.hasPrefix("TEST"), "\(what) names no device: \(subject)")
            case "DEVICE_MANAGEMENT_SETTING": #expect(configurations.contains(subject), "\(what) names no configuration: \(subject)")
            case "LOCATION": #expect(units.contains(subject), "\(what) names no org unit: \(subject)")
            default: break
            }
            if event.actorType?.rawValue == "USER" { #expect(users.contains(event.actorID ?? ""), "\(what)'s actor is no user") }
            if let config = event.payload?.configID { #expect(configurations.contains(config), "\(what) names no configuration: \(config)") }
            for location in event.payload?.roleLocations ?? [] {
                #expect(units.contains(location.locationID ?? ""), "\(what) names no org unit: \(location.locationID ?? "none")")
            }
        }
        #expect(events.contains { $0.subjectType?.rawValue == "USER" } && events.contains { $0.subjectType?.rawValue == "LOCATION" })
    }

    /// The Apple MDM devices are the fleet's: a row on that screen is a row on Devices, by serial.
    @Test func theAppleMDMDevicesAreTheFleets() async throws {
        let world = try await Self.demo()
        world.appleMDM.load()
        await eventually("the Apple MDM list") { if case .loaded = world.appleMDM.state { true } else { false } }
        let serials = Set(DemoFleet.make().devices.map(\.id))
        #expect(world.appleMDM.devices.count == 15)
        #expect(world.appleMDM.devices.allSatisfy { serials.contains($0.id) && $0.serialNumber == $0.id })
    }
}
