import Foundation
import FoundationModels
import Testing
@testable import Assist

/// A strict stand-in for the on-device model (invariant 5: the stub fails like the API). Each call takes the next scripted
/// reply; a call with none scripted fails the test. A `.json` reply is held to what guided generation can return: a field
/// the schema requires and the reply leaves out is thrown as `GeneratedContent.ParsingError`, as the SDK throws it ("does not
/// contain a property", the shared lessons), and a value off a listed `anyOf` fails the test, since constrained decoding can't
/// write one. `.unchecked` skips both, for the defence code keeps against an answer the SDK isn't meant to give. `.error`
/// throws the SDK's own error values (`LanguageModelError`'s cases are built with their public initializers).
final class StubModel: Picker.Asking, @unchecked Sendable {
    enum Reply {
        case json(String)
        case unchecked(String)
        case error(any Error)
    }

    struct Call {
        let instructions: String
        let prompt: String
        let schema: GenerationSchema
    }

    let availability: SystemLanguageModel.Availability
    let supportsLocale: Bool
    private let lock = NSLock()
    private var replies: [Reply]
    private var made: [Call] = []

    init(_ replies: [Reply] = [], availability: SystemLanguageModel.Availability = .available, supportsLocale: Bool = true) {
        self.replies = replies
        self.availability = availability
        self.supportsLocale = supportsLocale
    }

    var calls: [Call] { lock.withLock { made } }
    var unused: Int { lock.withLock { replies.count } }

    enum Unscripted: Error { case call }

    func answer(instructions: String, prompt: String, schema: GenerationSchema) async throws -> GeneratedContent {
        let reply: Reply? = lock.withLock {
            made.append(Call(instructions: instructions, prompt: prompt, schema: schema))
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        switch reply {
        case nil:
            Issue.record("an unscripted call to the model")
            throw Unscripted.call
        case .error(let error)?:
            throw error
        case .unchecked(let json)?:
            return try GeneratedContent(json: json)
        case .json(let json)?:
            let shape = try Self.shape(schema)
            let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            if let missing = shape.required.first(where: { fields[$0] == nil }) {
                throw GeneratedContent.ParsingError(rawContent: json, debugDescription: "GeneratedContent does not contain a property '\(missing)'.")
            }
            for (name, allowed) in shape.enums {
                if let value = fields[name] as? String, !allowed.contains(value) {
                    Issue.record("guided generation can't write \(value) for \(name): script it .unchecked")
                }
            }
            return try GeneratedContent(json: json)
        }
    }

    /// The schema's required fields and each `anyOf`'s values, read from its own JSON encoding.
    static func shape(_ schema: GenerationSchema) throws -> (required: [String], enums: [String: [String]]) {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any] ?? [:]
        let properties = object["properties"] as? [String: [String: Any]] ?? [:]
        var enums: [String: [String]] = [:]
        for (name, property) in properties { if let values = property["enum"] as? [String] { enums[name] = values } }
        return (object["required"] as? [String] ?? [], enums)
    }

    /// An answer of the pick schema.
    static func pick(_ label: String, words: String = "devices") -> Reply {
        let object = ["pick": label, "words": words]
        return .json(String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
