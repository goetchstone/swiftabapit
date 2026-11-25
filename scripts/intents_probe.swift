// The App Intents as the system sees them, from outside the app (AppIntentsTesting, by bundle ID): CI only, through
// scripts/intents_test.sh, against the Release build it registered. Never run on the operator's Mac: `--run` launches abapit.
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
if CommandLine.arguments.contains("--run") {
    // No organization on the runner: the no-key answer is the screens' own words, said, never a crash or a hang.
    let result = try await definitions.intents["NeedsAttentionIntent"].makeIntent().run()
    let value: String = try result.value
    print("intents_probe: Needs attention answered: \(value)")
    guard value.contains("organization") else { exit(1) }
}
