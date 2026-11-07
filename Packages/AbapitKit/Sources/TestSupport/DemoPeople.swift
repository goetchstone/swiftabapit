#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

/// The demo org's people (plan §4, demo mode): 25 users, four user groups and three org units, with their members, for
/// the People screen and its snapshots. Invented: every name is made up, every address at `example.com` (Managed Apple
/// Accounts at `appleid.example.com`, as Apple's own example), every phone number in the 555-01xx range kept for fiction,
/// every id an obvious fake (`DEMO…`). Written out rather than drawn from a seed, so the screenshots don't move; dates
/// count back from `DemoFleet.reference`. The mix shows what the screen says: every user status, external users, numbers
/// of each type, people holding roles in two org units, a smart group, and one group member the users list lacks
/// (someone who left: their id stays in the group), shown by id.
public enum DemoPeople {
    /// The org units: `(id, name, description)`.
    static let units = [
        ("DEMOOU01", "Head Office", "Leadership, finance and people operations"),
        ("DEMOOU02", "Field Services", "Technicians and site supervisors"),
        ("DEMOOU03", "Design Studio", "Product, graphic and motion design"),
    ]

    /// One demo user: their org unit and a second role's are indexes into `units`.
    struct Person {
        let number: Int, first: String, last: String, status: String, external: Bool, department: String, title: String
        let unit: Int, role: String, second: Int?, phones: [String]

        init(_ number: Int, _ first: String, _ last: String, _ status: String, _ external: Bool, _ department: String, _ title: String,
             _ unit: Int, _ role: String, _ second: Int?, _ phones: [String]) {
            (self.number, self.first, self.last, self.status, self.external) = (number, first, last, status, external)
            (self.department, self.title, self.unit, self.role, self.second, self.phones) = (department, title, unit, role, second, phones)
        }

        var id: String { DemoPeople.userID(number) }
    }

    static let people: [Person] = [
        Person(1, "Ada", "Fernhill", "ACTIVE", false, "Operations", "Operations Lead", 0, "Manager", 2, ["WORK", "MOBILE"]),
        Person(2, "Bram", "Castellane", "ACTIVE", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(3, "Cleo", "Varga", "ACTIVE", false, "Design", "Product Designer", 2, "Staff", nil, ["WORK"]),
        Person(4, "Dario", "Lindqvist", "NEW", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(5, "Elif", "Saranda", "ACTIVE", false, "Finance", "Accountant", 0, "Staff", nil, ["WORK"]),
        Person(6, "Farah", "Quennell", "ACTIVE", false, "People", "People Partner", 0, "Staff", nil, ["WORK", "HOME"]),
        Person(7, "Gideon", "Thorne", "ACTIVE", false, "Field", "Site Supervisor", 1, "Manager", 0, ["WORK", "MOBILE"]),
        Person(8, "Hana", "Oyelaran", "ACTIVE", true, "Design", "Illustrator", 2, "Staff", nil, ["MOBILE"]),
        Person(9, "Ilse", "Brennvik", "ACTIVE", false, "IT", "Systems Administrator", 0, "Administrator", 1, ["WORK", "MOBILE"]),
        Person(10, "In\u{E9}s", "Duarte", "DEACTIVATED", false, "Field", "Technician", 1, "Staff", nil, []),
        Person(11, "Kenji", "Morrow", "ACTIVE", false, "Design", "Motion Designer", 2, "Staff", nil, ["WORK"]),
        Person(12, "Lena", "Hartigan", "ACTIVE", false, "Finance", "Controller", 0, "Manager", nil, ["WORK"]),
        Person(13, "Mateo", "Ferrand", "LOCKED", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(14, "Nadia", "Pellworth", "ACTIVE", false, "Design", "Design Lead", 2, "Manager", 0, ["WORK", "MOBILE"]),
        Person(15, "Oskar", "Ellery", "ACTIVE", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(16, "Priya", "Ramaswell", "ACTIVE", false, "Operations", "Office Coordinator", 0, "Staff", nil, ["WORK"]),
        Person(17, "Quinn", "Atherby", "ACTIVE", true, "Design", "Copywriter", 2, "Staff", nil, ["HOME"]),
        Person(18, "Rosa", "Delacourt", "ACTIVE", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(19, "Soren", "Haldane", "ACTIVE", false, "IT", "Support Specialist", 0, "Staff", 1, ["WORK"]),
        Person(20, "Tamsin", "Coldwell", "RELEASED", false, "Finance", "Payroll Specialist", 0, "Staff", nil, []),
        Person(21, "Umar", "Fairbairn", "ACTIVE", false, "Field", "Technician", 1, "Staff", nil, ["MOBILE"]),
        Person(22, "Vera", "Ostrova", "NEW", true, "Design", "Freelance Designer", 2, "Staff", nil, ["MOBILE"]),
        Person(23, "Wren", "Kittering", "LOCKED_FOR_SHARED_IPAD", false, "Field", "Apprentice", 1, "Staff", nil, []),
        Person(24, "Yusuf", "Brightwater", "ACTIVE", false, "Operations", "Facilities Manager", 0, "Manager", nil, ["WORK", "MOBILE"]),
        Person(25, "Zoe", "Ambrel", "ACTIVE", false, "Design", "UX Researcher", 2, "Staff", nil, ["WORK"]),
    ]

    static func userID(_ number: Int) -> String { String(format: "DEMOUSER%02d", number) }
    static func unitID(_ index: Int) -> String { units[index].0 }

    /// The address part of a name: lower case, ASCII (Inés is `ines`).
    static func local(_ first: String, _ last: String) -> String {
        "\(first).\(last)".applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? "\(first).\(last)".lowercased()
    }

    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {
        let day: TimeInterval = 86_400
        let reference = DemoFleet.reference
        func date(_ daysAgo: Double) -> JSONValue { .string(DemoFleet.iso(reference - daysAgo * day)) }

        var users: [Resource] = []
        for person in people {
            let name = local(person.first, person.last), number = person.number
            var roles: [JSONValue] = [.object(["roleName": .string(person.role), "ouId": .string(unitID(person.unit))])]
            if let second = person.second { roles.append(.object(["roleName": .string("Staff"), "ouId": .string(unitID(second))])) }
            let numbers: [JSONValue] = person.phones.enumerated().map { index, type in
                .object(["phoneNumber": .string(String(format: "+1 555-01%02d", (number * 3 + index) % 100)), "type": .string(type)])
            }
            users.append(Resource(type: "users", id: person.id, attributes: [
                "firstName": .string(person.first), "lastName": .string(person.last), "status": .string(person.status),
                "managedAppleAccount": .string("\(name)@appleid.example.com"), "isExternalUser": .bool(person.external),
                "roleOuList": .array(roles), "email": .string("\(name)@example.com"),
                "employeeNumber": .string(String(format: "E%04d", 1_000 + number)), "costCenter": .string("CC-\(100 + person.unit * 10)"),
                "division": .string(units[person.unit].1), "department": .string(person.department), "jobTitle": .string(person.title),
                "startDateTime": date(Double(60 + number * 37)), "createdDateTime": date(Double(70 + number * 37)),
                "updatedDateTime": date(Double(number % 9 + 1)), "phoneNumbers": .array(numbers),
            ]))
        }
        stub.add(users)

        stub.add(units.map { id, name, summary in
            Resource(type: "organizationalUnits", id: id, attributes: [
                "name": .string(name), "description": .string(summary), "createdDateTime": date(900), "updatedDateTime": date(30),
            ])
        })
        for (index, unit) in units.enumerated() {
            stub.relate("organizationalUnits", unit.0, "users", to: people.filter { $0.unit == index }.map(\.id))
        }

        // `(id, name, type, org unit, members)`. Finance Approvers keeps the id of someone who left (DEMOUSER26).
        let groups: [(String, String, String, Int, [String])] = [
            ("DEMOUG01", "Everyone", "STANDARD", 0, people.map(\.id)),
            ("DEMOUG02", "Field Technicians", "STANDARD", 1, people.filter { $0.unit == 1 && $0.title == "Technician" }.map(\.id)),
            ("DEMOUG03", "Designers", "SMART", 2, people.filter { $0.department == "Design" }.map(\.id)),
            ("DEMOUG04", "Finance Approvers", "STANDARD", 0, [userID(5), userID(12), userID(1), userID(26)]),
        ]
        stub.add(groups.map { id, name, type, unit, members in
            Resource(type: "userGroups", id: id, attributes: [
                "ouId": .string(unitID(unit)), "name": .string(name), "type": .string(type), "totalMemberCount": .number(String(members.count)),
                "status": .string("ACTIVE"), "createdDateTime": date(800), "updatedDateTime": date(12),
            ])
        })
        for group in groups { stub.relate("userGroups", group.0, "users", to: group.4) }
    }
}
#endif
