import Foundation
import GRDB
import NaturalLanguage

/// The "Auto" matching algorithm: learns tags, correspondents, document types and
/// storage paths from documents that are no longer in the inbox
/// (Paperless-ngx `documents/classifier.py`).
///
/// Paperless-ngx uses scikit-learn (CountVectorizer with 1-2 grams and an MLP).
/// FolioZero uses the same features with linear softmax / logistic models
/// trained by gradient descent, which need no dependencies and train in seconds.
public struct DocumentClassifier: Codable, Sendable {
    /// Bumped when the file format changes; older files are ignored.
    public static let formatVersion = 1

    var formatVersion = Self.formatVersion
    /// Fingerprint of the training data, to skip retraining when nothing changed.
    public var dataHash: String
    var vocabulary: [String: Int]
    var idf: [Float]
    var correspondent: SoftmaxModel?
    var documentType: SoftmaxModel?
    var storagePath: SoftmaxModel?
    var tags: [Int: BinaryModel]

    // MARK: Training

    public struct TrainingDocument: Sendable {
        public var content: String
        public var correspondentId: Int?
        public var documentTypeId: Int?
        public var storagePathId: Int?
        public var tagIds: Set<Int>

        public init(content: String, correspondentId: Int? = nil, documentTypeId: Int? = nil, storagePathId: Int? = nil, tagIds: Set<Int> = []) {
            self.content = content
            self.correspondentId = correspondentId
            self.documentTypeId = documentTypeId
            self.storagePathId = storagePathId
            self.tagIds = tagIds
        }
    }

    /// Loads training data: documents without inbox tags, labelled only with objects using `auto` matching.
    public static func trainingData(in db: Database) throws -> [TrainingDocument] {
        let autoCorrespondents = Set(try Int.fetchAll(db, sql: "SELECT id FROM correspondents WHERE matching_algorithm = 6"))
        let autoTypes = Set(try Int.fetchAll(db, sql: "SELECT id FROM document_types WHERE matching_algorithm = 6"))
        let autoPaths = Set(try Int.fetchAll(db, sql: "SELECT id FROM storage_paths WHERE matching_algorithm = 6"))
        let autoTags = Set(try Int.fetchAll(db, sql: "SELECT id FROM tags WHERE matching_algorithm = 6"))
        let rows = try Row.fetchAll(db, sql: """
            SELECT d.id, d.content, d.correspondent_id, d.document_type_id, d.storage_path_id,
                   (SELECT group_concat(tag_id) FROM document_tags WHERE document_id = d.id) AS tag_ids
            FROM documents d
            WHERE d.deleted_at IS NULL AND d.root_document_id IS NULL
              AND NOT EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id AND t.is_inbox_tag = 1)
            ORDER BY d.id
            """)
        return rows.map { row in
            let tagIds = Set(((row["tag_ids"] as String?) ?? "").split(separator: ",").compactMap { Int($0) })
            return TrainingDocument(
                content: row["content"],
                correspondentId: (row["correspondent_id"] as Int?).flatMap { autoCorrespondents.contains($0) ? $0 : nil },
                documentTypeId: (row["document_type_id"] as Int?).flatMap { autoTypes.contains($0) ? $0 : nil },
                storagePathId: (row["storage_path_id"] as Int?).flatMap { autoPaths.contains($0) ? $0 : nil },
                tagIds: tagIds.intersection(autoTags)
            )
        }
    }

    /// Fingerprint of the data, labels included.
    public static func hash(_ documents: [TrainingDocument]) -> String {
        var hasher = SHA256Stream()
        for d in documents {
            hasher.update(Data("\(d.content.count):\(d.content.hashValueStable)|\(d.correspondentId ?? -1)|\(d.documentTypeId ?? -1)|\(d.storagePathId ?? -1)|\(d.tagIds.sorted())\n".utf8))
        }
        return hasher.finalizeHex()
    }

    /// Trains a classifier. Returns nil when there is nothing to learn
    /// (no documents, or no labels using `auto`).
    public static func train(_ documents: [TrainingDocument], epochs: Int = 40) -> DocumentClassifier? {
        let hasLabels = documents.contains {
            $0.correspondentId != nil || $0.documentTypeId != nil || $0.storagePathId != nil || !$0.tagIds.isEmpty
        }
        guard documents.count >= 2, hasLabels else { return nil }

        let tokenized = documents.map { Self.features(of: $0.content) }
        // min_df = 1% of documents (at least 1), as in Paperless-ngx.
        let minDocs = max(1, Int((Double(documents.count) * 0.01).rounded(.up)))
        var documentFrequency: [String: Int] = [:]
        for tokens in tokenized { for token in Set(tokens) { documentFrequency[token, default: 0] += 1 } }
        let kept = documentFrequency.filter { $0.value >= minDocs }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(50_000)
        var vocabulary: [String: Int] = [:]
        for (index, entry) in kept.enumerated() { vocabulary[entry.key] = index }
        let n = Float(documents.count)
        var idf = [Float](repeating: 0, count: vocabulary.count)
        for (term, index) in vocabulary { idf[index] = log((1 + n) / (1 + Float(documentFrequency[term]!))) + 1 }

        let vectors = tokenized.map { Self.vector($0, vocabulary: vocabulary, idf: idf) }

        func softmax(_ label: (TrainingDocument) -> Int?) -> SoftmaxModel? {
            let labels = documents.map(label)
            let classes = Set(labels.compactMap { $0 })
            guard !classes.isEmpty else { return nil }
            return SoftmaxModel.train(vectors: vectors, labels: labels, classes: Array(classes).sorted(), dimensions: vocabulary.count, epochs: epochs)
        }

        var tagModels: [Int: BinaryModel] = [:]
        let allTags = Set(documents.flatMap(\.tagIds))
        for tag in allTags {
            let labels = documents.map { $0.tagIds.contains(tag) }
            tagModels[tag] = BinaryModel.train(vectors: vectors, labels: labels, dimensions: vocabulary.count, epochs: epochs)
        }

        return DocumentClassifier(
            dataHash: hash(documents),
            vocabulary: vocabulary,
            idf: idf,
            correspondent: softmax(\.correspondentId),
            documentType: softmax(\.documentTypeId),
            storagePath: softmax(\.storagePathId),
            tags: tagModels
        )
    }

    // MARK: Prediction

    public func predict(_ content: String, threshold: Float = 0) -> Classification.Suggestions {
        let vector = Self.vector(Self.features(of: content), vocabulary: vocabulary, idf: idf)
        func single(_ model: SoftmaxModel?) -> [Int] {
            guard let model, let (label, probability) = model.predict(vector), let label else { return [] }
            return probability >= threshold ? [label] : []
        }
        let tagIds = tags.compactMap { id, model in model.probability(vector) >= 0.5 ? id : nil }.sorted()
        return Classification.Suggestions(
            correspondentIds: single(correspondent),
            documentTypeIds: single(documentType),
            storagePathIds: single(storagePath),
            tagIds: tagIds
        )
    }

    // MARK: Persistence

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> DocumentClassifier? {
        guard let data = try? Data(contentsOf: url),
              let classifier = try? JSONDecoder().decode(DocumentClassifier.self, from: data),
              classifier.formatVersion == formatVersion else { return nil }
        return classifier
    }

    /// Trains from the database and saves, unless the data has not changed.
    /// Returns a description of what happened.
    @discardableResult
    public static func trainAndSave(app: FolioApp) async throws -> String {
        let documents = try await app.database.read { db in try trainingData(in: db) }
        let url = app.settings.classifierFile
        let digest = hash(documents)
        if let existing = load(from: url), existing.dataHash == digest {
            return "Training data unchanged; classifier not retrained"
        }
        guard let classifier = train(documents) else {
            try? FileManager.default.removeItem(at: url)
            return "No documents with automatic matching to learn from"
        }
        try classifier.save(to: url)
        return "Classifier trained on \(documents.count) documents"
    }

    // MARK: Features

    /// Lowercased word unigrams and bigrams, with stop words removed.
    static func features(of content: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        let text = content.lowercased()
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            if word.count > 1, !Self.stopWords.contains(word), word.contains(where: \.isLetter) || word.count >= 3 {
                words.append(word)
            }
            return words.count < 20_000
        }
        var result = words
        if words.count > 1 {
            for index in 0..<(words.count - 1) { result.append(words[index] + " " + words[index + 1]) }
        }
        return result
    }

    static func vector(_ tokens: [String], vocabulary: [String: Int], idf: [Float]) -> SparseVector {
        var counts: [Int: Float] = [:]
        for token in tokens { if let index = vocabulary[token] { counts[index, default: 0] += 1 } }
        var entries = counts.map { ($0.key, $0.value * idf[$0.key]) }
        let norm = sqrt(entries.reduce(0) { $0 + $1.1 * $1.1 })
        if norm > 0 { entries = entries.map { ($0.0, $0.1 / norm) } }
        return SparseVector(indices: entries.map(\.0), values: entries.map(\.1))
    }

    static let stopWords = Set([
        "the", "and", "for", "you", "your", "are", "with", "this", "that", "from", "have", "not", "was", "our", "will",
        "der", "die", "das", "und", "mit", "von", "für", "ist", "den", "des", "sie", "ein", "eine", "auf",
        "het", "een", "van", "en", "le", "la", "les", "de", "et", "du", "un", "une", "el", "los", "las",
    ])
}

struct SparseVector: Sendable {
    var indices: [Int]
    var values: [Float]
}

/// Multinomial logistic regression with an extra "none" class for unlabelled documents.
struct SoftmaxModel: Codable, Sendable {
    /// Class labels; `nil` is the "none" class.
    var labels: [Int?]
    /// Row-major [class][feature] weights.
    var weights: [Float]
    var bias: [Float]
    var dimensions: Int

    static func train(vectors: [SparseVector], labels: [Int?], classes: [Int], dimensions: Int, epochs: Int) -> SoftmaxModel {
        let allLabels: [Int?] = [nil] + classes.map { Optional($0) }
        let k = allLabels.count
        var model = SoftmaxModel(labels: allLabels, weights: [Float](repeating: 0, count: k * dimensions), bias: [Float](repeating: 0, count: k), dimensions: dimensions)
        let targets = labels.map { label in allLabels.firstIndex(of: label) ?? 0 }
        // Balance classes: rare classes get larger sample weights.
        var counts = [Int](repeating: 0, count: k)
        for t in targets { counts[t] += 1 }
        let sampleWeights = targets.map { Float(targets.count) / Float(k * max(counts[$0], 1)) }
        var order = Array(vectors.indices)
        var generator = SeededGenerator(seed: 42)
        let lambda: Float = 1e-4
        for epoch in 0..<epochs {
            order.shuffle(using: &generator)
            let rate: Float = 0.5 / (1 + Float(epoch) * 0.1)
            for i in order {
                let x = vectors[i]
                let p = model.probabilities(x)
                for c in 0..<k {
                    let gradient = (p[c] - (c == targets[i] ? 1 : 0)) * sampleWeights[i]
                    let row = c * dimensions
                    for (j, value) in zip(x.indices, x.values) {
                        model.weights[row + j] -= rate * (gradient * value + lambda * model.weights[row + j])
                    }
                    model.bias[c] -= rate * gradient
                }
            }
        }
        return model
    }

    func probabilities(_ x: SparseVector) -> [Float] {
        var scores = bias
        for c in 0..<labels.count {
            let row = c * dimensions
            var sum: Float = 0
            for (j, value) in zip(x.indices, x.values) { sum += weights[row + j] * value }
            scores[c] += sum
        }
        let maxScore = scores.max() ?? 0
        let exps = scores.map { exp($0 - maxScore) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    }

    /// Best label and its probability. A `nil` label means "none".
    func predict(_ x: SparseVector) -> (Int?, Float)? {
        let p = probabilities(x)
        guard let best = p.indices.max(by: { p[$0] < p[$1] }) else { return nil }
        return (labels[best], p[best])
    }
}

/// Binary logistic regression for one tag.
struct BinaryModel: Codable, Sendable {
    var weights: [Float]
    var bias: Float

    static func train(vectors: [SparseVector], labels: [Bool], dimensions: Int, epochs: Int) -> BinaryModel {
        var model = BinaryModel(weights: [Float](repeating: 0, count: dimensions), bias: 0)
        let positives = labels.filter { $0 }.count
        let negatives = labels.count - positives
        let positiveWeight = Float(labels.count) / Float(2 * max(positives, 1))
        let negativeWeight = Float(labels.count) / Float(2 * max(negatives, 1))
        var order = Array(vectors.indices)
        var generator = SeededGenerator(seed: 7)
        let lambda: Float = 1e-4
        for epoch in 0..<epochs {
            order.shuffle(using: &generator)
            let rate: Float = 0.5 / (1 + Float(epoch) * 0.1)
            for i in order {
                let x = vectors[i]
                let target: Float = labels[i] ? 1 : 0
                let gradient = (model.probability(x) - target) * (labels[i] ? positiveWeight : negativeWeight)
                for (j, value) in zip(x.indices, x.values) {
                    model.weights[j] -= rate * (gradient * value + lambda * model.weights[j])
                }
                model.bias -= rate * gradient
            }
        }
        return model
    }

    func probability(_ x: SparseVector) -> Float {
        var sum = bias
        for (j, value) in zip(x.indices, x.values) { sum += weights[j] * value }
        return 1 / (1 + exp(-sum))
    }
}

/// Deterministic shuffling so training is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension String {
    /// A hash that is stable across runs (Swift's `hashValue` is seeded per process).
    var hashValueStable: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return hash
    }
}
