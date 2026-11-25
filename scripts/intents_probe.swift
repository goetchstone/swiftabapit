// The App Intents as the system sees them, from outside the app (AppIntentsTesting, by bundle ID): CI only, through
// scripts/intents_test.sh, against the Release build it registered. It reads definitions and makes an intent; it runs none.
// Running one (`run()`) launches abapit, so never here on the operator's Mac; on CI's runner it ended "Underlying session was
// cancelled (transport cancelled)" for NeedsAttentionIntent (PR 52's first run), so the no-key answer isn't run: the intents ask
// for local device authentication, which the runner may refuse (unconfirmed: what that policy does on a Mac is a live check).
import AppIntentsTesting
import Foundation

let definitions = IntentDefinitions(bundleIdentifier: "io.github.goetchstone.swiftabapit")
let names = ["RunReportIntent", "NeedsAttentionIntent", "LookUpSerialIntent", "OutOfWarrantyIntent", "CoverageEndingIntent",
             "FleetAgeIntent", "ActivationLockIntent", "MigrationIntent", "ServiceHealthIntent"]
for name in names {
    let definition = definitions.intents[name]
    guard definition.identifier == name else {
        print("intents_probe: \(name) is defined as \(definition.identifier)")
        exit(1)
    }
}
// The parameters, by name and type: a report case, a group and a number for RunReportIntent; a serial for lookup.
let report = definitions.enums["ReportChoice"].makeCase("out-of-warranty")
let run = definitions.intents["RunReportIntent"].makeIntent(report: report, group: "no-record", number: 3)
print("intents_probe: \(names.count) intents defined; made \(run)")
let lookUp = definitions.intents["LookUpSerialIntent"].makeIntent(serial: "C02EXAMPLE01")
print("intents_probe: made \(lookUp)")
