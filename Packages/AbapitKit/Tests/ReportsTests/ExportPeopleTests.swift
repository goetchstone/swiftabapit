import AppleModels
import JSONAPI
import Testing
@testable import Reports

/// Invariant 11 for the People screen: each list exports its table's columns, then its other documented attributes, and
/// nothing else (ExportPolicyTests holds the writer and the denylist; this holds the three lists).
@Suite("People exports")
struct ExportPeopleTests {
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    /// The first row (CR LF is one `Character`).
    static func header(_ text: String) -> String { String(text.prefix { $0 != "\r\n" }) }

    /// The table's columns first, then every other attribute the view reads, in its order (a subset check would let a
    /// dropped or reordered column through), each once, none the denylist or `notByDefault` would drop (so a listed column
    /// can't vanish silently), and never a key Apple adds later.
    static func check(_ columns: ExportPolicy.Columns, table: [String], fields: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let names = columns.names
        #expect(names == table + fields.filter { !table.contains($0) }, sourceLocation: sourceLocation)
        #expect(Set(names) == Set(fields), "every column is a documented attribute, and every attribute a column", sourceLocation: sourceLocation)
        #expect(Set(names).count == names.count, sourceLocation: sourceLocation)
        for name in names {
            #expect(!ExportPolicy.isSensitive(name) && !ExportPolicy.isNotByDefault(name), "\(name)", sourceLocation: sourceLocation)
        }
        var attributes: JSONObject = [:]
        for field in fields { attributes[field] = .string("x") }
        attributes["someFutureAttribute"] = .string("not yet")
        attributes["accessToken"] = .string("SECRET-THAT-MUST-NOT-LEAVE")
        let text = CSV.text([CSV.Item(id: "X1", attributes: attributes)], columns: columns)
        #expect(bytes(header(text)) == bytes((["id"] + names).joined(separator: ",")), sourceLocation: sourceLocation)
        #expect(!text.contains("not yet") && !text.contains("SECRET-THAT-MUST-NOT-LEAVE"), sourceLocation: sourceLocation)
    }

    @Test func theUsersExportIsTheTablesColumnsThenTheRest() {
        Self.check(ExportPolicy.users, table: ["firstName", "middleName", "lastName", "managedAppleAccount", "email", "status", "isExternalUser",
                                               "department", "jobTitle", "startDateTime"], fields: User.fields)
    }

    @Test func theGroupsExportIsTheTablesColumnsThenTheRest() {
        Self.check(ExportPolicy.userGroups, table: ["name", "type", "status", "totalMemberCount", "ouId"], fields: UserGroup.fields)
    }

    @Test func theOrgUnitsExportIsTheTablesColumnsThenTheRest() {
        Self.check(ExportPolicy.organizationalUnits, table: ["name", "description"], fields: OrganizationalUnit.fields)
    }

    /// A whole user row, as the file holds it: a flag as Python writes it, an absent attribute empty, and a list of objects
    /// (phone numbers, roles) each item as JSON joined by "; ", quoted with its quotes doubled.
    @Test func aUserRowIsWrittenWhole() {
        let user: JSONObject = [
            "firstName": .string("Ada"), "lastName": .string("Fernhill"), "managedAppleAccount": .string("ada@appleid.example.com"),
            "email": .string("ada@example.com"), "status": .string("ACTIVE"), "isExternalUser": .bool(false),
            "startDateTime": .string("2024-02-01T09:00:00Z"),
            "roleOuList": .array([.object(["roleName": .string("Manager"), "ouId": .string("OU1")])]),
            "phoneNumbers": .array([.object(["phoneNumber": .string("+1 555-0100"), "type": .string("WORK")]),
                                    .object(["phoneNumber": .string("+1 555-0101"), "type": .string("MOBILE")])]),
        ]
        let text = CSV.text([CSV.Item(id: "u1", attributes: user)], columns: ExportPolicy.users)
        let row = text.split(separator: "\r\n").last.map(String.init) ?? ""
        let roles = #""{""ouId"":""OU1"",""roleName"":""Manager""}""#
        let phones = #""{""phoneNumber"":""+1 555-0100"",""type"":""WORK""}; {""phoneNumber"":""+1 555-0101"",""type"":""MOBILE""}""#
        #expect(Self.bytes(row) == Self.bytes("u1,Ada,,Fernhill,ada@appleid.example.com,ada@example.com,ACTIVE,False,,,2024-02-01T09:00:00Z,"
                                              + roles + ",,,,,," + phones))
    }

    /// A phone number in a cell of its own would be guarded as a formula (`+`); inside a list it starts with `{`, which isn't
    /// a trigger. The guard is the writer's, for any cell: a group named like a formula gets its `'`.
    @Test func aFormulaShapedNameIsGuarded() {
        let text = CSV.text([CSV.Item(id: "G1", attributes: ["name": .string("=HYPERLINK(\"x\")")])], columns: ExportPolicy.userGroups)
        #expect(text.split(separator: "\r\n").last.map(String.init)?.hasPrefix(#"G1,"'=HYPERLINK(""x"")""#) == true, "\(text)")
    }
}
