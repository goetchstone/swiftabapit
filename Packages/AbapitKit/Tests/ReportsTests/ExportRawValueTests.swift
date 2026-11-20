import AppleModels
import Foundation
import JSONAPI
import Testing
@testable import Reports

/// A value Apple sent in an unexpected shape is written as its JSON text, and a secret nested inside it never is (invariants 3
/// and 11): every report's CSV, with an object holding a canary under `apiKey`, `password` and `token`.
@Suite("Raw values in CSV cells")
struct ExportRawValueTests {
    static let canary = "CANARY-SECRET-VALUE"

    /// An object as Apple might send where a string is expected: a harmless key and three secret-looking ones, one nested deeper.
    static let object: JSONValue = .object(["note": .string("kept"), "apiKey": .string(canary), "password": .string(canary),
                                            "inner": .object(["token": .string(canary), "fine": .string("also kept")]),
                                            "list": .array([.object(["Api_Key": .string(canary)])])])

    static func check(_ text: String, _ name: String) {
        #expect(!text.contains(canary), "\(name): the canary left")
        #expect(text.contains(AuditEvent.withheld), "\(name): no withheld marker")
    }

    @Test func theMaskKeepsTheShapeAndWithholdsTheSecretKeys() {
        let text = shownJSON(Self.object)
        #expect(!text.contains(Self.canary))
        #expect(text.contains("note") && text.contains("kept") && text.contains("fine") && text.contains("also kept"))
        #expect(text.contains("apiKey") && text.contains("password") && text.contains("token") && text.contains("Api_Key"))
        #expect(text.components(separatedBy: AuditEvent.withheld).count - 1 == 4)
        // Past the walk's depth it is withheld whole.
        var deep: JSONValue = .object(["x": .string(Self.canary)])
        for _ in 0..<(AuditEvent.maskDepth + 2) { deep = .array([deep]) }
        #expect(!shownJSON(deep).contains(Self.canary))
    }

    @Test func warrantyCSVWithholdsSecretsInADateOrAnEnd() {
        let active = AppleCareCoverage(resource: Resource(type: "appleCareCoverage", id: "c", attributes: ["status": .string("ACTIVE"), "endDateTime": Self.object]))
        let devices = ["ACTIVE", "EMPTY"].map { Fleet.device($0, ["orderDateTime": Self.object]) }
        let report = WarrantyReport(devices, coverage: ["ACTIVE": .read([active]), "EMPTY": .read([])], now: Fleet.now)
        Self.check(CSV.text(report.csvItems, columns: ExportPolicy.warrantyReport), "warranty")
        Self.check(report.rows.flatMap(\.unreadableEnds).joined(), "warranty ends")
    }

    @Test func migrationCSVWithholdsSecrets() {
        let device = Fleet.device("M", ["mdmMigrationDeadlineDateTime": Self.object, "mdmMigrationStatus": Self.object, "isMdmMigrationCapable": Self.object])
        Self.check(CSV.text(MigrationReport([device], now: Fleet.now).csvItems, columns: ExportPolicy.migrationReport), "migration")
    }

    @Test func activationLockCSVWithholdsSecrets() {
        let status = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: ["isLocked": Self.object, "lockType": Self.object]))
        let report = ActivationLockReport([Fleet.device("L", ["deviceModel": Self.object, "productFamily": Self.object])], reads: ["L": .read(status)])
        Self.check(CSV.text(report.csvItems, columns: ExportPolicy.activationLockReport), "activation lock")
    }

    @Test func serviceHealthCSVWithholdsSecrets() {
        let service = MDMService(resource: Resource(type: "mdmServers", id: "S", attributes: [
            "serverName": .string("S"), "status": Self.object, "serverType": Self.object, "lastConnectedDateTime": Self.object, "deviceCount": Self.object]))
        Self.check(CSV.text(ServiceHealth([service], now: Fleet.now).csvItems, columns: ExportPolicy.serviceHealth), "service health")
    }

    @Test func historyCSVsWithholdSecrets() {
        let order = Resource(type: "orgDevices", id: "D1", attributes: ["orderDateTime": Self.object, "deviceModel": Self.object, "productFamily": Self.object, "addedToOrgDateTime": .string("2019-01-01T00:00:00Z")])
        let candidates = CoverageFleetAgeTests.fleetAge(devices: [order], applecare: [], years: 0, now: CoverageFleetAgeTests.now, notRead: [])
        #expect(!candidates.candidates.isEmpty)
        Self.check(ExportHistory.refreshCandidates(candidates), "refresh candidates")
        let record = Resource(type: "applecare", id: "D1:0", attributes: ["serialNumber": .string("D1"), "status": .string("ACTIVE"), "description": Self.object,
                                                                        "paymentType": Self.object, "endDateTime": .string(CoverageFleetAgeTests.stamp(86_400))])
        let expiring = CoverageFleetAgeTests.coverage(applecare: [record], devices: [order], days: 30, now: CoverageFleetAgeTests.now, notRead: [])
        #expect(expiring.expiring.count == 1)
        Self.check(ExportHistory.coverageExpiring(expiring), "coverage expiring")
    }
}
