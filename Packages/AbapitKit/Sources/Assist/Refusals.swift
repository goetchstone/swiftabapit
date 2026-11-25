import Foundation
import FoundationModels

/// Why a sentence gets no pick, in words. Each is said, never guessed past: a refusal is never turned into a nearby report.
/// The ones `Refusals.before` finds are found before any model call, so the model can't swap in something near the
/// impossible (the shared lessons: refuse the impossible first).
public enum Refusal: Sendable, Equatable {
    /// No client is open: nothing to answer for.
    case noClient
    /// The sentence is empty once trimmed.
    case empty
    /// The sentence is longer than `Picker.longest` characters (its length).
    case tooLong(Int)
    /// The sentence names Mosyle and the client has no Mosyle org.
    case mosyleWithoutOrg
    /// The on-device model can't answer on this Mac now.
    case unavailable(Unavailable)
    /// The model doesn't support this Mac's language.
    case unsupportedLocale
    /// The model was asked and its answer can't be used: never a guess.
    case notUnderstood(NotUnderstood)
    /// The model said none of the reports or checks fits.
    case notOnTheList

    /// `SystemLanguageModel.Availability.UnavailableReason`, as Assist words it (and one for a reason this version doesn't know).
    public enum Unavailable: Sendable, Equatable {
        case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, other
    }

    /// Why an answer couldn't be used: one per kind of failure, each worded by code. The error's own description is never shown:
    /// it may hold what the model wrote.
    public enum NotUnderstood: Sendable, Equatable {
        case guardrail, refused, rateLimited, timeout, tooMuchToRead, unreadable, unsupported, language, settingUp, busy
        /// Asked again once after a fault, and the answer still couldn't be used.
        case faultTwice
        /// An error this version doesn't know.
        case other
    }

    public var words: String {
        switch self {
        case .noClient: "There's no client to answer for: add or open a client first."
        case .empty: "There's nothing to read: ask about this client's devices in a sentence."
        case .tooLong(let count): "That's \(count) characters; ask in \(Picker.longest) or fewer."
        case .mosyleWithoutOrg: "This client has no Mosyle org, so nothing about Mosyle can be answered."
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model, so questions in words are off. The reports work as before."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off: turn it on in System Settings to ask in words. The reports work as before."
        case .unavailable(.modelNotReady): "The on-device model is still being set up (downloading). Try again in a while; the reports work as before."
        case .unavailable(.other): "The on-device model isn't available. The reports work as before."
        case .unsupportedLocale: "The on-device model doesn't support this Mac's language, so questions in words are off."
        case .notUnderstood(let why): "That wasn't understood: \(why.words). Nothing was picked."
        case .notOnTheList: "That isn't one of the reports or Needs-attention checks abapit answers. Nothing was picked."
        }
    }
}

extension Refusal.NotUnderstood {
    var words: String {
        switch self {
        case .guardrail: "the model's safety check stopped it"
        case .refused: "the model declined to answer"
        case .rateLimited: "the model is busy; try again in a moment"
        case .timeout: "the model took too long"
        case .tooMuchToRead: "there was more than the model can read at once"
        case .unreadable: "the model's answer didn't come out whole"
        case .unsupported: "the model can't answer this kind of request"
        case .language: "the model doesn't support this language"
        case .settingUp: "the on-device model is still being set up"
        case .busy: "the model is answering another request"
        case .faultTwice: "the model's answer couldn't be used, twice"
        case .other: "the model failed"
        }
    }

    /// What a thrown error means here. Cancellation is not a failure to understand: the caller rethrows it before this.
    static func from(_ error: any Error) -> Self {
        if error is GeneratedContent.ParsingError { return .unreadable }
        if error is SystemLanguageModel.Error { return .settingUp }
        if let error = error as? LanguageModelSession.Error {
            return error == .concurrentRequests ? .busy : .other
        }
        guard let error = error as? LanguageModelError else { return .other }
        return switch error {
        case .contextSizeExceeded: .tooMuchToRead
        case .rateLimited: .rateLimited
        case .guardrailViolation: .guardrail
        case .refusal: .refused
        case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide: .unsupported
        case .unsupportedLanguageOrLocale: .language
        case .timeout: .timeout
        @unknown default: .other
        }
    }
}

/// The refusals found before any model call, in this order: no client; an empty sentence or one too long; Mosyle named for a
/// client without it; the model unavailable; the language unsupported.
public enum Refusals {
    public static func before(_ sentence: String, client: Picker.Client?, model: some Picker.Asking) -> Refusal? {
        guard let client else { return .noClient }
        if sentence.isEmpty { return .empty }
        if sentence.count > Picker.longest { return .tooLong(sentence.count) }
        if !client.hasMosyle && namesMosyle(sentence) { return .mosyleWithoutOrg }
        switch model.availability {
        case .available: break
        case .unavailable(let reason): return .unavailable(unavailable(reason))
        }
        if !model.supportsLocale { return .unsupportedLocale }
        return nil
    }

    /// Whether "Mosyle" is a whole word of the sentence (any case; "Mosyle's" too).
    static func namesMosyle(_ sentence: String) -> Bool {
        sentence.lowercased().split { !($0.isLetter || $0.isNumber) }.contains("mosyle")
    }

    static func unavailable(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> Refusal.Unavailable {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .other
        }
    }
}
