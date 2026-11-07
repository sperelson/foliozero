import Foundation
import FoundationModels

/// Apple's on-device language model (FoundationModels, `SystemLanguageModel.default`).
///
/// Nothing leaves the Mac. Classification uses guided generation with a `@Generable`
/// type, so the answer always has the expected shape. Requires Apple Intelligence to be
/// turned on; `availabilityError()` explains what is missing when it is not.
public struct AppleLanguageModelBackend: LLMBackend {
    public let kind = LLMBackendKind.apple
    public var modelName: String { "system" }
    /// `AI_LLM_CONTEXT_SIZE`; the model's own window wins when it is smaller.
    public let configuredContextSize: Int
    /// `AI_LLM_REQUEST_TIMEOUT` in seconds.
    public let timeout: TimeInterval

    public init(contextSize: Int = 8192, timeout: TimeInterval = 120) {
        configuredContextSize = contextSize
        self.timeout = timeout
    }

    /// Why the on-device model cannot be used, or nil when it is ready.
    public static func availabilityError() -> AIError? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .modelUnavailable("This Mac does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .modelUnavailable("Apple Intelligence is turned off. Turn it on in System Settings > Apple Intelligence & Siri.")
            case .modelNotReady:
                return .modelUnavailable("The on-device model is not ready yet (it may still be downloading). Try again later.")
            @unknown default:
                return .modelUnavailable("The on-device model reports \(reason).")
            }
        }
    }

    /// True when the on-device model can answer requests now.
    public static var isAvailable: Bool { availabilityError() == nil }

    /// The smaller of `AI_LLM_CONTEXT_SIZE` and the model's window. When the model reports
    /// no usable size, 4096 (the FoundationModels default before macOS 27) is assumed.
    public func contextSize() async -> Int {
        let reported = SystemLanguageModel.default.contextSize
        return min(configuredContextSize, reported > 0 ? reported : Self.fallbackContextSize)
    }

    /// Context window assumed when the model does not report one.
    public static let fallbackContextSize = 4096

    public func tokenCount(_ text: String) async -> Int {
        (try? await SystemLanguageModel.default.tokenCount(for: text)) ?? estimatedTokenCount(text)
    }

    /// Tokens the classification schema adds to every request.
    func schemaTokenCount() async -> Int {
        (try? await SystemLanguageModel.default.tokenCount(for: AppleClassification.generationSchema)) ?? 800
    }

    public func generateClassification(instructions: String, prompt: String) async throws -> ClassifierOutput {
        if let error = Self.availabilityError() { throw error }
        let model = SystemLanguageModel(useCase: .general, guardrails: .default)
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            return try await withAITimeout(timeout) {
                let response = try await session.respond(
                    to: prompt,
                    generating: AppleClassification.self,
                    options: GenerationOptions(samplingMode: .greedy)
                )
                return response.content.output
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func streamChat(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let timeout = self.timeout
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let error = Self.availabilityError() {
                    continuation.finish(throwing: error)
                    return
                }
                // Chat answers are plain text drawn from document content, which may itself
                // be sensitive (medical, legal); permissive transformations avoid false refusals.
                let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: instructions)
                do {
                    try await withAITimeout(timeout) {
                        var sent = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let text = snapshot.content
                            if text.hasPrefix(sent) {
                                let delta = String(text.dropFirst(sent.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                            } else {
                                // The model revised earlier text; send the whole answer again.
                                continuation.yield(text)
                            }
                            sent = text
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Converts FoundationModels errors into `AIError`.
    static func map(_ error: Error) -> Error {
        if error is AIError || error is CancellationError { return error }
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return AIError.contextWindowExceeded
            case .rateLimited: return AIError.providerRejected(status: 429, message: "the on-device model is busy (rate limited)")
            case .guardrailViolation: return AIError.providerRejected(status: 0, message: "the on-device model's safety guardrails blocked the request")
            case .refusal: return AIError.providerRejected(status: 0, message: "the on-device model refused the request")
            case .unsupportedLanguageOrLocale(let detail): return AIError.unsupportedLanguage("language \(detail.languageCode.identifier)")
            case .timeout: return AIError.timeout
            default: return AIError.providerRejected(status: 0, message: error.localizedDescription)
            }
        }
        if let error = error as? SystemLanguageModel.Error {
            return AIError.modelUnavailable(error.localizedDescription)
        }
        if let error = error as? LanguageModelSession.Error {
            return AIError.providerRejected(status: 429, message: error.localizedDescription)
        }
        if error is GeneratedContent.ParsingError {
            return AIError.invalidResponse("the on-device model produced output that does not match the schema")
        }
        return AIError.providerRejected(status: 0, message: error.localizedDescription)
    }
}

/// Runs `operation`, throwing `AIError.timeout` when it takes longer than `seconds`.
func withAITimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw AIError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw AIError.timeout }
        return result
    }
}

/// Guided-generation twin of `ClassifierOutput`. Property names match the JSON keys the
/// prompt refers to (`matched_tags`, `tag_ids`, ...).
@Generable(description: "Classification suggestions for a single document.")
struct AppleClassification {
    @Guide(description: "A short, descriptive title for this document, at most 128 characters.")
    var title: String

    @Guide(description: "All topic labels you would suggest from the document itself, e.g. 'Insurance', 'Car', 'Warranty'. Always include every suggested name here, even when it matches an available tag.", .maximumCount(8))
    var tags: [String]

    @Guide(description: "Names copied exactly from tags that mean the same thing as an available tag. Align each name by position with tag_ids.", .maximumCount(8))
    var matched_tags: [String]

    @Guide(description: "Available tag IDs matching matched_tags, in the same order. Only use IDs shown in the prompt.", .maximumCount(10))
    var tag_ids: [Int]

    @Guide(description: "Who this document is from or was sent to, not every party merely mentioned. A document has a single correspondent, so give at most 4, best first, and prefer one name over several names for the same organisation. Always include every suggested name here, even when it matches an available correspondent.", .maximumCount(4))
    var correspondents: [String]

    @Guide(description: "Names copied exactly from correspondents that identify the same entity as an available correspondent. Align each name by position with correspondent_ids.", .maximumCount(4))
    var matched_correspondents: [String]

    @Guide(description: "Available correspondent IDs matching matched_correspondents, in the same order. Only use IDs shown in the prompt.", .maximumCount(4))
    var correspondent_ids: [Int]

    @Guide(description: "What kind of document this is, e.g. 'Invoice', 'Contract', 'Bank Statement', 'Letter'. Never use its subject or sender as a document type. A document has a single type, so give at most 4, best first. Always include every suggested name here, even when it matches an available document type.", .maximumCount(4))
    var document_types: [String]

    @Guide(description: "Names copied exactly from document_types that mean the same thing as an available document type. Align each name by position with document_type_ids.", .maximumCount(4))
    var matched_document_types: [String]

    @Guide(description: "Available document type IDs matching matched_document_types, in the same order. Only use IDs shown in the prompt.", .maximumCount(4))
    var document_type_ids: [Int]

    @Guide(description: "Folder-style filing location, e.g. 'Finance/Invoices'. Leave empty unless a filing location is clearly implied - never put tags, document types or correspondents here. A document has a single storage path, so give at most 4, best first. Always include every suggested name here, even when it matches an available storage path.", .maximumCount(4))
    var storage_paths: [String]

    @Guide(description: "Names copied exactly from storage_paths that mean the same filing location as an available storage path. Align each name by position with storage_path_ids.", .maximumCount(4))
    var matched_storage_paths: [String]

    @Guide(description: "Available storage path IDs matching matched_storage_paths, in the same order. Only use IDs shown in the prompt.", .maximumCount(4))
    var storage_path_ids: [Int]

    @Guide(description: "Up to 3 dates relevant to this document, each formatted YYYY-MM-DD. The most important is the date the document was issued.", .maximumCount(3))
    var dates: [String]

    var output: ClassifierOutput {
        ClassifierOutput(
            title: title, tags: tags, matchedTags: matched_tags, tagIds: tag_ids,
            correspondents: correspondents, matchedCorrespondents: matched_correspondents, correspondentIds: correspondent_ids,
            documentTypes: document_types, matchedDocumentTypes: matched_document_types, documentTypeIds: document_type_ids,
            storagePaths: storage_paths, matchedStoragePaths: matched_storage_paths, storagePathIds: storage_path_ids,
            dates: dates
        )
    }
}
