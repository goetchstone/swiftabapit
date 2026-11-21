import AppleBusiness
import AppleModels
import Foundation
import History
import JSONAPI

/// What a snapshot keeps of each Apple resource, and nothing else (plan Phase 3; docs/domains/history.md, "The Apple
/// collector"). The operator decided it on 2026-11-20, answering "Minimal (Recommended)": devices, services, apps, packages,
/// configurations, AppleCare and Activation Lock as abapit kept them, minus package download URLs, services' last-connected
/// IPs, MDM-detail IMEI/MEID/MAC addresses and error text (codes only); people only the Managed Apple Account, status,
/// external flag and dates, no names, emails, phones, job titles or departments; and (2026-10-31) no custom setting's
/// profile, so a configuration is kept as `Configuration.resource`, its profile withheld. Later the same day the operator
/// answered "Leave them out (Recommended)" for the device list's IMEI, MEID and MAC addresses too, "Keep them
/// (Recommended)" for blueprints (not their members), and "All three" for user groups' names and org-unit ids and the
/// device name Apple's MDM reports.
///
/// Each resource's attributes are an **allowlist**, written out here and compared by bytes: an attribute Apple adds later is
/// left out until a review adds it, and the snapshot's note counts what was left out that this version doesn't know (never
/// its name). abapit stored every attribute Apple sent; a denylist here would store the next one unreviewed.
public enum SnapshotPolicy {
    /// One resource a snapshot records.
    public struct Rule: Sendable, Equatable {
        /// Its name in the store: abapit's (`devices`, `mdm_servers`, `assignments`, …), so abapit's views and an imported
        /// history read the same rows.
        public let name: String
        /// The attributes kept, by Apple's names, in Apple's documented order. Nothing else is stored.
        public let kept: [String]
        /// Every attribute this version knows the read sends (the view's `fields`, held to Apple's contract by
        /// `ModelContractTests`): an attribute outside `known` and `kept` is one Apple added since, counted in the note.
        public let known: [String]
        /// Apple School Manager's API has no such read (plan §2.4): a School org's snapshot doesn't try it.
        public let businessOnly: Bool
        /// Every string kept goes through `ContentWords.addresses(in:)`, as a package's row, detail and CSV do, so a user
        /// and password written into its name or description never reach the file (invariant 11).
        public let masksAddresses: Bool
        /// Kept attributes Apple sends as an object, with the inner keys kept: only `customSettingsValues` (`CustomSettingsValues`: its
        /// file name and the withheld profile's marker). Every other kept attribute is a scalar or a list of scalars in
        /// `Contracts/apple/`, and `keep` stores nothing else under it.
        public let nested: [String: [String]]

        init(_ name: String, kept: [String], known: [String], businessOnly: Bool = false, masksAddresses: Bool = false, nested: [String: [String]] = [:]) {
            self.nested = nested
            self.name = name
            self.kept = kept
            self.known = known
            self.businessOnly = businessOnly
            self.masksAddresses = masksAddresses
        }
    }

    // MARK: the lists the collector reads

    /// `orgDevices`, keyed by serial number: every attribute Apple documents (the operator: devices as abapit kept them) but
    /// the IMEI, the MEID and every MAC address (the operator, 2026-11-20: "Leave them out (Recommended)"), and `eid`, the
    /// eSIM's identifier: a hardware identifier of the same kind (the coordinating session's reading of that answer, the side
    /// that stores less; the operator can overrule it).
    public static let devices = Rule("devices", kept: [
        "serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel", "productFamily",
        "productType", "deviceCapacity", "partNumber", "orderNumber", "color", "status", "orderDateTime",
        "purchaseSourceId", "purchaseSourceType", "isMdmMigrationCapable", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime",
    ], known: OrgDevice.fields)

    /// `mdmServers`: everything but `lastConnectedIp` (the operator's minus list).
    public static let services = Rule("mdm_servers", kept: [
        "createdDateTime", "defaultProductFamilies", "deviceCount", "enableMdmDisownFlag", "lastConnectedDateTime", "serverName",
        "serverType", "status", "updatedDateTime",
    ], known: MDMService.fields)

    /// Which service holds which device, as abapit recorded it: one item per serial, `serverId` and `serverName`, built
    /// from each service's device list.
    public static let assignments = Rule("assignments", kept: ["serverId", "serverName"], known: ["serverId", "serverName"])

    /// `users`: the Managed Apple Account, status, external flag and dates only (the operator). No name, email, phone,
    /// job title, department, cost centre, division, employee number or roles.
    public static let users = Rule("users", kept: [
        "status", "managedAppleAccount", "isExternalUser", "startDateTime", "createdDateTime", "updatedDateTime",
    ], known: User.fields, businessOnly: true)

    /// `userGroups`: every attribute Apple documents, the name and the org unit's id included (the operator, 2026-11-20,
    /// asked about user groups' names and org-unit ids and the MDM device name: "All three").
    public static let userGroups = Rule("user_groups", kept: ["ouId", "name", "type", "totalMemberCount", "status", "createdDateTime", "updatedDateTime"],
                                        known: UserGroup.fields, businessOnly: true)

    public static let apps = Rule("apps", kept: ["name", "bundleId", "websiteUrl", "version", "supportedOS", "isCustomApp", "appStoreUrl"],
                                  known: ContentApp.fields, businessOnly: true)

    /// `packages`: everything but `url`, the download location (the operator's minus list), each string with any address in
    /// it masked as the Content screen masks it.
    public static let packages = Rule("packages", kept: ["name", "hash", "bundleIds", "description", "version", "createdDateTime", "updatedDateTime"],
                                      known: ContentPackage.fields, businessOnly: true, masksAddresses: true)

    /// `blueprints`, the list as abapit kept it (the operator, 2026-11-20: "Keep them (Recommended)"): every attribute Apple
    /// documents, `appLicenseDeficient` included (Apple's blueprint resource carries it, and abapit stored what the list
    /// sent). Never its members: the list read sends none (no `include`), the store keeps no relationships, and the six
    /// relationship reads are never made for a snapshot.
    public static let blueprints = Rule("blueprints", kept: ["name", "description", "status", "appLicenseDeficient", "createdDateTime", "updatedDateTime"],
                                        known: Blueprint.fields, businessOnly: true)

    /// `configurations`, from `Configuration.resource`: a custom setting's profile withheld (operator, 2026-10-31), and read
    /// from the list, which sends it as null; the single read that carries it is never made for a snapshot.
    public static let configurations = Rule("configurations", kept: [
        "type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime",
    ], known: Configuration.fields, businessOnly: true, nested: ["customSettingsValues": ["configurationProfile", "filename"]])

    /// `mdmDevices`, as abapit kept the list (`mdm_enrolled`): every attribute, `deviceName` included (the operator,
    /// 2026-11-20: "All three").
    public static let mdmEnrolled = Rule("mdm_enrolled", kept: ["serialNumber", "deviceName", "productFamily", "enrolledUserId"],
                                         known: MDMDevice.fields, businessOnly: true)

    /// The lists, in the order a snapshot reads them (abapit's `_collect`). Not kept: org units, blueprints' members, audit
    /// events and webhooks.
    public static let lists: [Rule] = [devices, services, assignments, users, userGroups, apps, packages, blueprints, configurations, mdmEnrolled]

    // MARK: the sweeps (one read per device; `Sweep` runs them when a run asks)

    /// `orgDevices/{serial}/appleCareCoverage`, as abapit's `fetch_applecare_bulk` kept it: every attribute, and the serial
    /// number it was read for (`applecare_view` reads it); each record under Apple's id, or `serial:description` without one.
    public static let appleCare = Rule("applecare", kept: [
        "agreementNumber", "contractCancelDateTime", "description", "endDateTime", "isCanceled", "isRenewable", "paymentType",
        "startDateTime", "status", "serialNumber",
    ], known: AppleCareCoverage.fields + ["serialNumber"])

    /// `orgDevices/{serial}/activationLockStatus`, keyed by serial (`activation_lock_view`).
    public static let activationLock = Rule(SnapshotStore.activationLockResource, kept: ["isLocked", "lockType"], known: ActivationLockStatus.fields)

    /// `mdmDevices/{id}/details`: the posture and the device's name (the operator's minus list: no IMEI, MEID or MAC
    /// address; `deviceName` kept, 2026-11-20: "All three").
    public static let mdmDetails = Rule("mdm_details", kept: [
        "serialNumber", "deviceName", "deviceModel", "osVersion", "platform", "lastCheckInDateTime", "isFirewallEnabled", "isFileVaultEnabled",
        "storageFreeCapacity", "storageTotalCapacity", "deviceLockStatus", "deviceEraseStatus", "lostModeStatus",
    ], known: MDMDeviceDetail.fields, businessOnly: true)

    /// The per-device sweeps (plan §3.6: bounded fan-out at the limiter's rate, cancellable; `Sweep`). A run that doesn't
    /// ask for one has it in neither `counts` nor `errors`.
    public static let sweeps: [Rule] = [appleCare, activationLock, mdmDetails]

    public static let all: [Rule] = lists + sweeps

    // MARK: keeping

    /// One item as a snapshot keeps it.
    package struct Kept {
        package let item: Resource
        /// The attributes left out that this version doesn't know (Apple added them) or whose shape it doesn't keep (an object where
        /// a scalar is kept), by their bytes: counted in the snapshot's note, never stored or named.
        package let unknown: Set<[UInt8]>
        /// Whether a string of it had an address masked.
        package let masked: Bool
    }

    /// `resource` with only `rule.kept`'s attributes, compared by bytes (a key canonically equal to a kept one but other
    /// bytes is another key), and with `rule.masksAddresses`, every string of them through `ContentWords.addresses(in:)`.
    ///
    /// The one home of "a snapshot keeps no custom setting's profile" (operator, 2026-10-31): the resource goes through
    /// `Configuration(resource:).resource` first, whatever its rule, so a profile in any attribute is withheld however the item
    /// came (a list read sends null; abapit's history held the single read's profile). A kept attribute keeps only a scalar or a
    /// list of scalars, or for `rule.nested` an object's listed inner keys with scalar values: a nested object under a kept name
    /// (a device model that is `{imei: …}`) is left out and counted, never stored whole.
    package static func keep(_ resource: Resource, _ rule: Rule) -> Kept {
        let resource = Configuration(resource: resource).resource
        let kept = Set(rule.kept.map { Array($0.utf8) }), known = Set(rule.known.map { Array($0.utf8) })
        var attributes = JSONObject(), unknown: Set<[UInt8]> = [], masked = false
        for (key, value) in resource.attributes {
            let bytes = Array(key.utf8)
            guard kept.contains(bytes) else {
                if !known.contains(bytes) { unknown.insert(bytes) }
                continue
            }
            guard let shaped = scalars(value, inner: rule.nested.first { Array($0.key.utf8) == bytes }?.value) else {
                unknown.insert(bytes)
                continue
            }
            if rule.masksAddresses {
                let shown = shaped.mappingStrings(ContentWords.addresses(in:))
                masked = masked || shown != shaped
                attributes[key] = shown
            } else {
                attributes[key] = shaped
            }
        }
        return Kept(item: Resource(type: rule.name, id: resource.id, attributes: attributes), unknown: unknown, masked: masked)
    }

    /// `value` if it is a scalar or a list of scalars; for an attribute with `inner` keys, an object cut to those keys when each
    /// is a scalar; otherwise nil (left out whole).
    private static func scalars(_ value: JSONValue, inner: [String]?) -> JSONValue? {
        func scalar(_ value: JSONValue) -> Bool {
            switch value {
            case .null, .bool, .number, .string: true
            case .array, .object: false
            }
        }
        switch value {
        case .null, .bool, .number, .string: return value
        case .array(let items): return items.allSatisfy(scalar) ? value : nil
        case .object(let object):
            guard let inner else { return nil }
            let allowed = Set(inner.map { Array($0.utf8) })
            var out = JSONObject()
            for (key, member) in object where allowed.contains(Array(key.utf8)) {
                guard scalar(member) else { return nil }
                out[key] = member
            }
            return .object(out)
        }
    }

    // MARK: errors

    /// An error as a snapshot records it: a code, never Apple's text or a URL (the operator: "error text (codes only)").
    /// The HTTP status and Apple's error `code` when it has a code's shape (`appleCode`), or this app's word for a failure
    /// that has no status.
    public static func code(_ error: any Error) -> String {
        // The client throws a transport failure as it came (`HTTPFailure`): `.of` names it `.http`, so it is `transport`.
        switch AppleAPIError.of(error) ?? error {
        case let error as AppleAPIError:
            switch error {
            case .unauthorized: "HTTP 401"
            case .forbidden(let code): status(403, code)
            case .notFound: "HTTP 404"
            case .conflict(let code, _): status(409, code)
            case .unprocessable: "HTTP 422"
            case .badRequest(let code, _, _): status(400, code)
            case .rateLimited: "HTTP 429"
            case .server(let status), .unexpected(let status): "HTTP \(status)"
            case .notJSON: "not JSON"
            case .malformed: "malformed"
            // What happened, never the host: an answer past the cap or a refused host isn't "no answer".
            case .http:
                switch error.httpKind {
                case .tooLarge?: "too large"
                case .refusedHost?: "refused host"
                case .noAnswer?, nil: "transport"
                }
            case .token: "token"
            case .vault: "keychain"
            case .wrongHost: "wrong host"
            case .notInScope, .webhooksNotInScope: "not in scope"
            }
        case is CancellationError: "cancelled"
        default: "failed"
        }
    }

    private static func status(_ status: Int, _ code: String?) -> String {
        ["HTTP \(status)", appleCode(code)].compactMap { $0 }.joined(separator: " ")
    }

    /// Apple's error `code` (`FORBIDDEN_ERROR`, `PARAMETER_ERROR.INVALID`) when it is two or more words of capital ASCII
    /// letters joined by `_` or `.`, at most 64 bytes; anything else (prose, an identifier, a name) is dropped.
    static func appleCode(_ text: String?) -> String? {
        guard let text, (1...64).contains(text.utf8.count) else { return nil }
        let words = text.utf8.split(omittingEmptySubsequences: false) { $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }
        guard words.count >= 2, words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) } })
        else { return nil }
        return text
    }

    /// The error of a list the page cap cut: kept as read, but a part read, never a good copy (`SnapshotStore.latest`), so
    /// a Needs-attention rule doesn't judge it as whole.
    public static let pageCap = "page cap"

    /// A failure after which no more is asked of the org in this run: the key, the token or the account. Every later read
    /// would fail the same way, and a Touch ID refused once would be asked again for each.
    static func stopsTheRun(_ error: any Error) -> Bool {
        switch error as? AppleAPIError {
        case .unauthorized?, .token?, .vault?: true
        default: false
        }
    }
}
