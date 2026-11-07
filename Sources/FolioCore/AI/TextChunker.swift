import Foundation

/// Splits and trims document text for embeddings and prompts. Sizes are in tokens,
/// estimated at four characters per token (`estimatedTokenCount`).
public enum TextChunker {
    /// Paperless-ngx `RAG_CHUNK_OVERLAP`.
    public static let defaultOverlap = 200

    /// Paperless-ngx `_normalize_llm_index_text`: OCR leader runs (`....`, `____`) and
    /// runs of horizontal whitespace become one space.
    public static func normalize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "[._\\-\u{00B7}]{4,}", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
        return result
    }

    /// Splits `text` into chunks of at most `chunkSize` tokens. Consecutive chunks share
    /// up to `overlap` tokens (Paperless-ngx: `min(200, chunk_size - 1)`). Chunks end at a
    /// sentence or line break when one falls in the second half of the chunk.
    public static func chunks(_ text: String, chunkSize: Int, overlap: Int = defaultOverlap) -> [String] {
        let maxChars = max(chunkSize, 4) * 4
        let overlapChars = min(max(0, min(overlap, chunkSize - 1)) * 4, maxChars / 2)
        let pieces = Self.pieces(of: text, maxChars: maxChars)
        guard !pieces.isEmpty else { return [] }
        let lengths = pieces.map(\.count)

        var chunks: [String] = []
        var start = 0
        while start < pieces.count {
            var end = start
            var length = 0
            while end < pieces.count, end == start || length + lengths[end] <= maxChars {
                length += lengths[end]
                end += 1
            }
            if end < pieces.count {
                // Prefer to stop after a sentence or line, if that keeps at least half a chunk.
                var running = length
                var candidate = end
                while candidate > start, running >= maxChars / 2 {
                    if endsSentence(pieces[candidate - 1]) {
                        end = candidate
                        break
                    }
                    running -= lengths[candidate - 1]
                    candidate -= 1
                }
            }
            let chunk = pieces[start..<end].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            if end >= pieces.count { break }
            var next = end
            var shared = 0
            while next > start + 1, shared + lengths[next - 1] <= overlapChars {
                next -= 1
                shared += lengths[next]
            }
            start = next
        }
        return chunks
    }

    /// The first `tokens` tokens of `text`, cut at a word boundary
    /// (Paperless-ngx `truncate_embedding_query`).
    public static func prefix(_ text: String, tokens: Int) -> String {
        let maxChars = max(tokens, 1) * 4
        guard text.count > maxChars else { return text }
        let cut = text.index(text.startIndex, offsetBy: maxChars)
        var head = text[..<cut]
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: head.startIndex, to: space) > maxChars / 2 {
            head = head[..<space]
        }
        return String(head)
    }

    /// Words with their trailing whitespace; words longer than `maxChars` are split.
    static func pieces(of text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var inWhitespace = false
        for character in text {
            if character.isWhitespace {
                inWhitespace = true
                current.append(character)
            } else {
                if inWhitespace {
                    pieces.append(current)
                    current = ""
                    inWhitespace = false
                }
                current.append(character)
                if current.count >= maxChars {
                    pieces.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func endsSentence(_ piece: String) -> Bool {
        if piece.contains("\n") { return true }
        let word = piece.trimmingCharacters(in: .whitespaces)
        guard let last = word.last else { return false }
        return ".!?;:".contains(last)
    }
}
