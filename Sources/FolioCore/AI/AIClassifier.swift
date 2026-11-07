import Foundation
import GRDB
import Logging

/// What the model suggested for one taxonomy: ids of existing objects it picked from the
/// candidates it was shown, and names it proposed (Paperless-ngx `TaxonomyChoiceDict`).
public struct TaxonomyChoice: Codable, Sendable, Equatable {
    public var existingIds: [Int]
    public var newNames: [String]

    public init(existingIds: [Int] = [], newNames: [String] = []) {
        self.existingIds = existingIds
        self.newNames = newNames
    }

    enum CodingKeys: String, CodingKey {
        case existingIds = "existing_ids"
        case newNames = "new_names"
    }
}

/// Raw model suggestions before permission filtering (Paperless-ngx `ClassificationSuggestions`).
/// This is what the suggestion cache stores; ids are resolved per requester.
public struct ClassificationSuggestions: Codable, Sendable, Equatable {
    public var title: String
    public var tags: TaxonomyChoice
    public var correspondents: TaxonomyChoice
    public var documentTypes: TaxonomyChoice
    public var storagePaths: TaxonomyChoice
    public var dates: [String]

    public init(title: String = "", tags: TaxonomyChoice = .init(), correspondents: TaxonomyChoice = .init(),
                documentTypes: TaxonomyChoice = .init(), storagePaths: TaxonomyChoice = .init(), dates: [String] = []) {
        self.title = title; self.tags = tags; self.correspondents = correspondents
        self.documentTypes = documentTypes; self.storagePaths = storagePaths; self.dates = dates
    }

    enum CodingKeys: String, CodingKey {
        case title, tags, correspondents, dates
        case documentTypes = "document_types"
        case storagePaths = "storage_paths"
    }

    /// Validates the model's candidate mappings (Paperless-ngx `model_to_classification_suggestions`):
    /// a mapping counts only when its name is one of the model's own suggestions and its id
    /// was shown for that category. Everything else stays a new name.
    init(output: ClassifierOutput, allowedIds: [AIMatching.Kind: Set<Int>]) {
        func choice(_ names: [String], _ matched: [String], _ ids: [Int], _ kind: AIMatching.Kind) -> TaxonomyChoice {
            var remaining = names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            var existing: [Int] = []
            let allowed = allowedIds[kind] ?? []
            for (name, id) in zip(matched, ids) {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let position = remaining.firstIndex(of: name), allowed.contains(id), !existing.contains(id) else { continue }
                remaining.remove(at: position)
                existing.append(id)
            }
            return TaxonomyChoice(existingIds: existing, newNames: remaining)
        }
        self.init(
            title: output.title,
            tags: choice(output.tags, output.matchedTags, output.tagIds, .tag),
            correspondents: choice(output.correspondents, output.matchedCorrespondents, output.correspondentIds, .correspondent),
            documentTypes: choice(output.documentTypes, output.matchedDocumentTypes, output.documentTypeIds, .documentType),
            storagePaths: choice(output.storagePaths, output.matchedStoragePaths, output.storagePathIds, .storagePath),
            dates: output.dates
        )
    }

    /// The flat shape used for localization (`classification_suggestions_to_model`).
    var flatOutput: ClassifierOutput {
        ClassifierOutput(title: title, tags: tags.newNames, correspondents: correspondents.newNames,
                         documentTypes: documentTypes.newNames, storagePaths: storagePaths.newNames, dates: dates)
    }
}

/// Builds the classification prompt and asks the model (Paperless-ngx `ai_classifier`).
struct AIClassifier: Sendable {
    let database: FolioDatabase
    let index: LLMIndex
    let runtime: AIRuntime
    let logger: Logging.Logger

    /// Characters of document content in the prompt (Paperless-ngx `[:4000]`).
    static let contentCharacters = 4000
    /// Similar documents whose text goes into the prompt (`get_taxonomy_context` `max_docs`).
    static let ragDocuments = 5
    /// Characters of each similar document's text in the prompt.
    static let ragCharacters = 1000

    /// Suggestions for `documentId`, using only data `context` may see
    /// (Paperless-ngx `get_ai_document_classification`).
    func classify(documentId: Int, context: AccessContext, outputLanguage: String?) async throws -> ClassificationSuggestions {
        guard let document = try await database.read({ db in try Document.fetchOne(db, key: documentId) }) else {
            throw AIError.documentNotFound(documentId)
        }
        let content = try await database.read { db in
            try String.fetchOne(db, sql: """
                SELECT content FROM documents WHERE root_document_id = ? AND deleted_at IS NULL
                ORDER BY version_index DESC LIMIT 1
                """, arguments: [documentId])
        } ?? document.content

        let (candidates, ragContext) = await taxonomyContext(documentId: documentId, context: context)
        let llm = runtime.llm
        let taxonomyBlock = AIPrompts.taxonomyBlock(candidates)
        let filename = document.filename ?? ""
        func prompt(contentLimit: Int, rag: String) -> String {
            AIPrompts.withRAGContext(
                AIPrompts.classification(filename: filename, content: String(content.prefix(contentLimit)),
                                         taxonomyBlock: taxonomyBlock, hasCandidates: !candidates.isEmpty),
                context: rag)
        }

        let budget = await promptBudget(llm)
        var contentLimit = Self.contentCharacters
        var rag = ragContext
        var text = prompt(contentLimit: contentLimit, rag: rag)
        for _ in 0..<8 {
            let tokens = await llm.tokenCount(text)
            if tokens <= budget { break }
            if !rag.isEmpty {
                rag = rag.count > 400 ? String(rag.prefix(rag.count / 2)) : ""
            } else {
                let scaled = Int(Double(contentLimit) * Double(budget) / Double(tokens) * 0.9)
                guard scaled >= 200, scaled < contentLimit else { break }
                contentLimit = scaled
            }
            text = prompt(contentLimit: contentLimit, rag: rag)
        }

        let output: ClassifierOutput
        do {
            output = try await llm.generateClassification(instructions: llmSystemPrompt, prompt: text)
        } catch AIError.contextWindowExceeded {
            logger.warning("Classification prompt for document #\(documentId) exceeded the context window; retrying with less content")
            output = try await llm.generateClassification(instructions: llmSystemPrompt, prompt: prompt(contentLimit: contentLimit / 2, rag: ""))
        }
        var suggestions = ClassificationSuggestions(output: output, allowedIds: candidates.allowedIds)

        if let outputLanguage, !outputLanguage.isEmpty {
            let localized = try await localize(suggestions, language: outputLanguage)
            // Existing ids always come from the original answer; correspondents and dates are never localized.
            func merge(_ original: TaxonomyChoice, _ translated: TaxonomyChoice) -> TaxonomyChoice {
                TaxonomyChoice(existingIds: original.existingIds,
                               newNames: translated.newNames.isEmpty ? original.newNames : translated.newNames)
            }
            suggestions = ClassificationSuggestions(
                title: localized.title.isEmpty ? suggestions.title : localized.title,
                tags: merge(suggestions.tags, localized.tags),
                correspondents: suggestions.correspondents,
                documentTypes: merge(suggestions.documentTypes, localized.documentTypes),
                storagePaths: merge(suggestions.storagePaths, localized.storagePaths),
                dates: suggestions.dates)
        }
        logger.debug("AI classification for document #\(documentId) done with \(llm.kind.rawValue):\(llm.modelName)")
        return suggestions
    }

    func localize(_ suggestions: ClassificationSuggestions, language: String) async throws -> ClassificationSuggestions {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(suggestions.flatOutput), as: UTF8.self)
        let prompt = AIPrompts.localization(languageName: AIPrompts.languageName(language), suggestionsJSON: json)
        let output = try await runtime.llm.generateClassification(instructions: llmSystemPrompt, prompt: prompt)
        return ClassificationSuggestions(output: output, allowedIds: [:])
    }

    /// Tokens available for the prompt: context window minus answer, instructions and schema.
    func promptBudget(_ llm: any LLMBackend) async -> Int {
        let contextSize = await llm.contextSize()
        let instructions = await llm.tokenCount(llmSystemPrompt)
        let schema: Int
        if let apple = llm as? AppleLanguageModelBackend {
            schema = await apple.schemaTokenCount()
        } else {
            let data = (try? JSONEncoder().encode(ClassifierOutput.jsonSchema)) ?? Data()
            schema = estimatedTokenCount(String(decoding: data, as: UTF8.self))
        }
        return max(256, contextSize - llmReservedOutputTokens - instructions - schema)
    }

    /// Taxonomy candidates and text of similar documents (Paperless-ngx `get_taxonomy_context`).
    /// Uses the LLM index when it has content, otherwise full-text "more like this".
    /// Failures degrade to no candidates, never to an error.
    func taxonomyContext(documentId: Int, context: AccessContext) async -> (TaxonomyCandidates, String) {
        do {
            var similar: [(documentId: Int, weight: Double)] = []
            if runtime.embedder != nil, try index.exists() {
                let matches = try await index.similarChunks(to: documentId, context: context, limit: LLMIndex.taxonomyTopK)
                var weights: [Int: Double] = [:]
                var order: [Int] = []
                for match in matches {
                    if weights[match.documentId] == nil { order.append(match.documentId) }
                    weights[match.documentId, default: 0] += Double(match.score)
                }
                similar = order.map { ($0, weights[$0] ?? 0) }.sorted { $0.1 > $1.1 }
            }
            if similar.isEmpty {
                let topK = LLMIndex.taxonomyTopK
                let hits = try await database.read { db in
                    try SearchIndex.moreLikeThis(
                        documentId: documentId, in: db,
                        visibility: context.visibilityPredicate(objectType: Document.objectType, alias: "d"), limit: topK)
                }
                similar = hits.enumerated().map { ($0.element.documentId, Double(topK - $0.offset)) }
            }
            let ranked = similar
            return try await database.read { db in
                let candidates = try TaxonomyCandidates.build(similar: ranked, context: context, in: db)
                var blocks: [String] = []
                for entry in ranked where blocks.count < Self.ragDocuments {
                    guard let row = try Row.fetchOne(db, sql: """
                        SELECT d.id, d.title, d.filename, d.owner_id,
                               COALESCE((SELECT v.content FROM documents v WHERE v.root_document_id = d.id AND v.deleted_at IS NULL
                                         ORDER BY v.version_index DESC LIMIT 1), d.content) AS content
                        FROM documents d WHERE d.id = ? AND d.deleted_at IS NULL
                        """, arguments: [entry.documentId]),
                        try context.can(.view, objectType: Document.objectType, objectId: entry.documentId, ownerId: row["owner_id"], in: db)
                    else { continue }
                    let title = (row["title"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? row["filename"] ?? "Untitled"
                    blocks.append("TITLE: \(title)\n\(String((row["content"] as String? ?? "").prefix(Self.ragCharacters)))")
                }
                return (candidates, blocks.joined(separator: "\n\n"))
            }
        } catch {
            logger.error("Failed to retrieve similar-document context for document #\(documentId); continuing without it: \(error)")
            return (TaxonomyCandidates(), "")
        }
    }
}
