import AppleModels
import Foundation
import JSONAPI
import Testing
import TestSupport

/// The models against Apple's own documentation (plan §3.10, invariant 10): every attribute a view reads is
/// one Apple documents, every enum's known cases are Apple's values, and Apple's examples decode.
@Suite("Apple models against the contract")
struct ModelContractTests {
    static var manifest: [String: Any] {
        let url = Fixtures.contracts.appending(path: "apple/business-2.6.json")
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]) ?? [:]
    }

    static func properties(_ object: String) -> [String] {
        let objects = manifest["objects"] as? [String: Any] ?? [:]
        let record = objects[object] as? [String: Any] ?? [:]
        return (record["properties"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    static func values(_ enumName: String) -> [String] {
        let enums = manifest["enums"] as? [String: Any] ?? [:]
        return (enums[enumName] as? [String: Any])?["values"] as? [String] ?? []
    }

    /// Each view reads exactly the attributes Apple documents for it: none it doesn't, and it doesn't skip one.
    @Test(arguments: [("OrgDevice.Attributes", OrgDevice.fields), ("AppleCareCoverage.Attributes", AppleCareCoverage.fields),
                      ("ActivationLockStatus.Attributes", ActivationLockStatus.fields), ("MdmServer.Attributes", MDMService.fields)])
    func aViewReadsApplesAttributes(object: String, fields: [String]) {
        let documented = Self.properties(object)
        #expect(!documented.isEmpty, "no \(object) in the manifest")
        #expect(Set(fields) == Set(documented), "\(object): reads \(Set(fields).subtracting(documented).sorted()), skips \(Set(documented).subtracting(fields).sorted())")
    }

    /// An enum Apple names has exactly Apple's values as known cases.
    @Test func namedEnumsHaveApplesValues() {
        func raw<T: KnownValues>(_: T.Type) -> Set<String> { Set(T.allCases.map(\.rawValue)) }
        #expect(raw(MigrationStatus.self) == Set(Self.values("MdmMigrationStatus")))
        #expect(raw(CoverageStatus.self) == Set(Self.values("AppleCareCoverageStatus")))
        #expect(raw(PaymentType.self) == Set(Self.values("AppleCareCoveragePaymentType")))
        #expect(raw(LockType.self) == Set(Self.values("ActivationLockType")))
        #expect(raw(ServiceStatus.self) == Set(Self.values("MdmServerStatus")))
        #expect(raw(ServiceProductFamily.self) == Set(Self.values("MdmServerProductFamily")))
    }

    static func example(_ name: String) throws -> Document {
        try Document.parse(Data(contentsOf: Fixtures.docc.appending(path: "business/\(name).response.json")))
    }

    /// Apple's examples decode, and what they send that the views don't read is only the documented gap.
    @Test func applesExamplesDecode() throws {
        let devices = try Self.example("get-org-devices").resources.map(OrgDevice.init)
        let device = try #require(devices.first)
        #expect(device.serialNumber == "XABC123X0ABC123X0")
        #expect(device.productFamily == .known(.mac))
        #expect(device.status == .known(.unassigned))
        #expect(device.imei.count == 2)
        // Apple's own example says purchaseSourceUid where its field list says purchaseSourceId (2.6): read the
        // documented name, and let the example's survive raw.
        #expect(device.unreadAttributes == ["purchaseSourceUid"])
        #expect(device.attributes["purchaseSourceUid"] != nil)

        let coverage = try Self.example("get-all-applecare-coverage-for-an-orgdevice").resources.map(AppleCareCoverage.init)
        #expect(coverage.contains { $0.paymentType == .known(.abeSubscription) })
        #expect(coverage.allSatisfy { $0.unreadAttributes.isEmpty })

        let lock = try ActivationLockStatus(resource: #require(Self.example("get-the-activation-lock-status-information-for-an-orgdevice").resource))
        #expect(lock.isLocked == true && lock.lockType == .known(.mdm) && !lock.blocksRelease)

        let services = try Self.example("get-mdm-servers").resources.map(MDMService.init)
        #expect(services.first?.name == "Test Device Management Service")
        #expect(services.first?.type == .known(.mdm))
    }

    @Test func anUnknownValueSurvivesRaw() {
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "X", attributes: [
            "productFamily": .string("Glasses"), "status": .string("PENDING_RELEASE"), "brandNewField": .bool(true)]))
        #expect(device.productFamily == .unknown("Glasses"))
        #expect(device.status?.rawValue == "PENDING_RELEASE")
        #expect(device.unreadAttributes == ["brandNewField"])
    }

    @Test func findMatchesEveryIdentifier() {
        let device = OrgDevice(resource: Resource(type: "orgDevices", id: "C02X", attributes: [
            "serialNumber": .string("C02X"), "imei": .array([.string("111"), .string("222")]), "meid": .array([.string("333")]),
            "eid": .string("444"), "orderNumber": .string("O-1"), "wifiMacAddress": .string("aa:bb"), "bluetoothMacAddress": .string("cc:dd"),
            "ethernetMacAddress": .array([.string("ee:ff")])]))
        #expect(Set(device.identifiers) == ["C02X", "111", "222", "333", "444", "O-1", "aa:bb", "cc:dd", "ee:ff"])
    }
}
