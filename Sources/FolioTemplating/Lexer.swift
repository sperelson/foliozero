import Foundation

/// The kind of tag next to a text chunk; it decides which whitespace rules apply.
enum TagKind: Sendable {
    case variable, block, comment, rawBegin, rawEnd

    /// `trim_blocks` removes the first newline after these tags.
    var trimsFollowingNewline: Bool {
        switch self {
        case .block, .comment, .rawEnd: true
        case .variable, .rawBegin: false
        }
    }

    /// `lstrip_blocks` removes the indentation before these tags.
    var stripsPrecedingIndent: Bool { self != .variable }
}

/// The `-` or `+` written inside a delimiter, as in `{%-` or `+%}`.
enum WhitespaceModifier: Sendable {
    case none, minus, plus
}

struct TagEdge: Sendable {
    var kind: TagKind
    var modifier: WhitespaceModifier
}

struct WhitespaceOptions: Sendable {
    var trimBlocks: Bool
    var lstripBlocks: Bool
    var keepTrailingNewline: Bool
}

/// Literal template text. Whitespace control depends on the environment, so it is applied at
/// render time from the tags on either side.
struct TextChunk: Sendable {
    var text: String
    /// The tag just before the text, with its closing modifier.
    var before: TagEdge?
    /// The tag just after the text, with its opening modifier.
    var after: TagEdge?
    var isTemplateStart: Bool
    var isTemplateEnd: Bool

    func rendered(_ options: WhitespaceOptions) -> String {
        let trimsStart = before.map { $0.modifier == .minus
            || ($0.modifier == .none && options.trimBlocks && $0.kind.trimsFollowingNewline) } ?? false
        let stripsEnd = after.map { $0.modifier == .minus
            || ($0.modifier == .none && options.lstripBlocks && $0.kind.stripsPrecedingIndent) } ?? false
        let dropsNewline = isTemplateEnd && !options.keepTrailingNewline && text.hasSuffix("\n")
        if !trimsStart && !stripsEnd && !dropsNewline { return text }

        var s = Array(text.unicodeScalars)
        if dropsNewline { s.removeLast() }

        // Jinja's lexer knows whether the text starts a line: at the template start, or after a
        // tag whose trimming consumed a newline.
        var lineStarting = isTemplateStart
        if let before {
            if before.modifier == .minus {
                let count = s.prefix(while: Py.isWhitespace).count
                lineStarting = count > 0 && s[count - 1] == "\n"
                s.removeFirst(count)
            } else if trimsStart, s.first == "\n" {
                s.removeFirst()
                lineStarting = true
            }
        }
        if let after {
            if after.modifier == .minus {
                while let last = s.last, Py.isWhitespace(last) { s.removeLast() }
            } else if stripsEnd {
                let lastNewline = s.lastIndex(of: "\n")
                let lineStart = lastNewline.map { $0 + 1 } ?? 0
                if lastNewline != nil || lineStarting,
                   s[lineStart...].allSatisfy({ Py.isWhitespace($0) && $0 != "\n" }) {
                    s.removeSubrange(lineStart...)
                }
            }
        }
        return Py.string(s)
    }
}

enum TokenKind: Sendable {
    case text(TextChunk)
    case variableBegin, variableEnd, blockBegin, blockEnd
    case name(String)
    case string(String)
    case integer(Int)
    case float(Double)
    case op(String)
    case eof
}

struct Token: Sendable {
    var kind: TokenKind
    var location: SourceLocation

    /// How the token reads in an error message.
    var display: String {
        switch kind {
        case .text: "text"
        case .variableBegin: "'{{'"
        case .variableEnd: "'}}'"
        case .blockBegin: "'{%'"
        case .blockEnd: "'%}'"
        case .name(let name): "'\(name)'"
        case .string(let value): "string \(Py.reprString(value))"
        case .integer(let value): "'\(value)'"
        case .float(let value): "'\(Py.floatRepr(value))'"
        case .op(let op): "'\(op)'"
        case .eof: "end of template"
        }
    }

    func isName(_ name: String) -> Bool {
        if case .name(name) = kind { return true }
        return false
    }

    func isOp(_ op: String) -> Bool {
        if case .op(op) = kind { return true }
        return false
    }
}

/// Splits template source into text and tag tokens.
struct Lexer {
    private struct Tag {
        var kind: TagKind
        var left: WhitespaceModifier
        var right: WhitespaceModifier
        var tokens: [Token]
        var location: SourceLocation
        var endLocation: SourceLocation
    }

    private enum Item {
        case text(String, SourceLocation)
        case tag(Tag)
    }

    private let chars: [Unicode.Scalar]
    private var index = 0
    private var line = 1
    private var column = 1

    init(_ source: String) {
        // Normalise \r\n and \r to \n, as Jinja does.
        var normalized: [Unicode.Scalar] = []
        normalized.reserveCapacity(source.unicodeScalars.count)
        var previousWasReturn = false
        for scalar in source.unicodeScalars {
            if scalar == "\r" {
                normalized.append("\n")
                previousWasReturn = true
                continue
            }
            if scalar == "\n" && previousWasReturn {
                previousWasReturn = false
                continue
            }
            previousWasReturn = false
            normalized.append(scalar)
        }
        chars = normalized
    }

    private var location: SourceLocation { SourceLocation(line: line, column: column) }

    private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
        let position = index + offset
        return position < chars.count ? chars[position] : nil
    }

    private mutating func advance(_ count: Int = 1) {
        for _ in 0..<count where index < chars.count {
            if chars[index] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            index += 1
        }
    }

    private func matches(_ text: String, at position: Int? = nil) -> Bool {
        var position = position ?? index
        for scalar in text.unicodeScalars {
            guard position < chars.count, chars[position] == scalar else { return false }
            position += 1
        }
        return true
    }

    private func isTagStart(_ position: Int) -> Bool {
        guard position + 1 < chars.count, chars[position] == "{" else { return false }
        let next = chars[position + 1]
        return next == "{" || next == "%" || next == "#"
    }

    // MARK: Top level

    mutating func tokenize() throws -> [Token] {
        var items: [Item] = []
        while index < chars.count {
            let textLocation = location
            var text: [Unicode.Scalar] = []
            while index < chars.count && !isTagStart(index) {
                text.append(chars[index])
                advance()
            }
            if !text.isEmpty { items.append(.text(Py.string(text), textLocation)) }
            guard index < chars.count else { break }

            let opened = location
            let opener = chars[index + 1]
            advance(2)
            var left = WhitespaceModifier.none
            if peek() == "-" {
                left = .minus
                advance()
            } else if peek() == "+" && opener != "{" {
                left = .plus
                advance()
            }

            switch opener {
            case "{":
                var tag = try lexTagContents(kind: .variable, opened: opened)
                tag.left = left
                items.append(.tag(tag))
            case "%":
                var tag = try lexTagContents(kind: .block, opened: opened)
                tag.left = left
                if tag.tokens.count == 1, tag.tokens[0].isName("raw") {
                    tag.kind = .rawBegin
                    items.append(.tag(tag))
                    try lexRawContent(opened: opened, into: &items)
                } else {
                    items.append(.tag(tag))
                }
            default:
                var tag = try lexComment(opened: opened)
                tag.left = left
                items.append(.tag(tag))
            }
        }
        return flatten(items)
    }

    private func flatten(_ items: [Item]) -> [Token] {
        var tokens: [Token] = []
        for (position, item) in items.enumerated() {
            switch item {
            case let .text(text, textLocation):
                var before: TagEdge?
                var after: TagEdge?
                if position > 0, case .tag(let tag) = items[position - 1] {
                    before = TagEdge(kind: tag.kind, modifier: tag.right)
                }
                if position + 1 < items.count, case .tag(let tag) = items[position + 1] {
                    after = TagEdge(kind: tag.kind, modifier: tag.left)
                }
                let chunk = TextChunk(
                    text: text, before: before, after: after,
                    isTemplateStart: position == 0, isTemplateEnd: position == items.count - 1
                )
                tokens.append(Token(kind: .text(chunk), location: textLocation))
            case .tag(let tag):
                switch tag.kind {
                case .variable:
                    tokens.append(Token(kind: .variableBegin, location: tag.location))
                    tokens.append(contentsOf: tag.tokens)
                    tokens.append(Token(kind: .variableEnd, location: tag.endLocation))
                case .block:
                    tokens.append(Token(kind: .blockBegin, location: tag.location))
                    tokens.append(contentsOf: tag.tokens)
                    tokens.append(Token(kind: .blockEnd, location: tag.endLocation))
                case .comment, .rawBegin, .rawEnd:
                    break
                }
            }
        }
        tokens.append(Token(kind: .eof, location: location))
        return tokens
    }

    // MARK: Tags

    private mutating func skipWhitespace() {
        while let scalar = peek(), Py.isWhitespace(scalar) { advance() }
    }

    private mutating func lexTagContents(kind: TagKind, opened: SourceLocation) throws -> Tag {
        var tokens: [Token] = []
        var brackets: [Unicode.Scalar] = []
        let (opener, closer) = kind == .variable ? ("{{", "}}") : ("{%", "%}")
        while true {
            skipWhitespace()
            guard index < chars.count else {
                throw makeSyntaxError("'\(opener)' is never closed; expected '\(closer)'", at: opened)
            }
            if brackets.isEmpty {
                let end = location
                for (text, modifier) in [("-" + closer, WhitespaceModifier.minus), ("+" + closer, .plus), (closer, .none)]
                where matches(text) && (modifier != .plus || kind == .block) {
                    advance(text.unicodeScalars.count)
                    return Tag(kind: kind, left: .none, right: modifier, tokens: tokens, location: opened, endLocation: end)
                }
            }
            tokens.append(try lexToken(brackets: &brackets, previous: tokens.last))
        }
    }

    private mutating func lexComment(opened: SourceLocation) throws -> Tag {
        let contentStart = index
        while index < chars.count {
            if matches("#}") {
                var right = WhitespaceModifier.none
                if index > contentStart {
                    if chars[index - 1] == "-" { right = .minus } else if chars[index - 1] == "+" { right = .plus }
                }
                let end = location
                advance(2)
                return Tag(kind: .comment, left: .none, right: right, tokens: [], location: opened, endLocation: end)
            }
            advance()
        }
        throw makeSyntaxError("Comment is never closed; expected '#}'", at: opened)
    }

    /// Reads the literal content of a raw block and its `{% endraw %}` tag.
    private mutating func lexRawContent(opened: SourceLocation, into items: inout [Item]) throws {
        let textLocation = location
        var text: [Unicode.Scalar] = []
        while index < chars.count {
            if matches("{%"), let (left, right, length) = matchEndraw(at: index) {
                if !text.isEmpty { items.append(.text(Py.string(text), textLocation)) }
                let end = location
                advance(length)
                items.append(.tag(Tag(kind: .rawEnd, left: left, right: right, tokens: [], location: end, endLocation: end)))
                return
            }
            text.append(chars[index])
            advance()
        }
        throw makeSyntaxError("Raw block is never closed; expected '{% endraw %}'", at: opened)
    }

    private func matchEndraw(at start: Int) -> (WhitespaceModifier, WhitespaceModifier, Int)? {
        var position = start + 2
        func modifier() -> WhitespaceModifier {
            guard position < chars.count else { return .none }
            switch chars[position] {
            case "-": position += 1; return .minus
            case "+": position += 1; return .plus
            default: return .none
            }
        }
        let left = modifier()
        while position < chars.count, Py.isWhitespace(chars[position]) { position += 1 }
        guard matches("endraw", at: position) else { return nil }
        position += 6
        while position < chars.count, Py.isWhitespace(chars[position]) { position += 1 }
        let right = modifier()
        guard matches("%}", at: position) else { return nil }
        return (left, right, position + 2 - start)
    }

    // MARK: Tokens inside tags

    private static func isDigit(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return ("0"..."9").contains(scalar)
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (Py.isWordCharacter(scalar) && scalar.properties.numericType == nil)
    }

    private mutating func lexToken(brackets: inout [Unicode.Scalar], previous: Token?) throws -> Token {
        let start = location
        let scalar = chars[index]

        if Self.isIdentifierStart(scalar) {
            var name: [Unicode.Scalar] = []
            while let next = peek(), Py.isWordCharacter(next) {
                name.append(next)
                advance()
            }
            return Token(kind: .name(Py.string(name)), location: start)
        }
        if Self.isDigit(scalar) {
            return try lexNumber(start: start, afterDot: previous?.isOp(".") ?? false)
        }
        if scalar == "'" || scalar == "\"" {
            return try lexString(start: start)
        }
        for op in ["//", "**", "==", "!=", "<=", ">="] where matches(op) {
            advance(2)
            return Token(kind: .op(op), location: start)
        }
        switch scalar {
        case "(", "[", "{":
            brackets.append(scalar == "(" ? ")" : (scalar == "[" ? "]" : "}"))
        case ")", "]", "}":
            guard let expected = brackets.last else {
                throw makeSyntaxError("Unexpected '\(scalar)'", at: start)
            }
            guard expected == scalar else {
                throw makeSyntaxError("Unexpected '\(scalar)'; expected '\(expected)'", at: start)
            }
            brackets.removeLast()
        case "+", "-", "*", "/", "%", "~", "<", ">", "=", ".", ":", "|", ",":
            break
        default:
            throw makeSyntaxError("Unexpected character '\(scalar)'", at: start)
        }
        advance()
        return Token(kind: .op(String(scalar)), location: start)
    }

    private mutating func lexNumber(start: SourceLocation, afterDot: Bool) throws -> Token {
        if peek() == "0", let prefix = peek(1), let radix = ["x": 16, "X": 16, "o": 8, "O": 8, "b": 2, "B": 2][prefix] {
            advance(2)
            var digits = ""
            while let next = peek(), next == "_" || next.properties.isASCIIHexDigit {
                if next != "_" { digits.unicodeScalars.append(next) }
                advance()
            }
            guard let value = Int(digits, radix: radix) else {
                throw makeSyntaxError("Invalid integer literal", at: start)
            }
            return Token(kind: .integer(value), location: start)
        }

        var text = ""
        func readDigits() {
            while let next = peek(), Self.isDigit(next) || next == "_" {
                if next != "_" { text.unicodeScalars.append(next) }
                advance()
            }
        }
        readDigits()
        var isFloat = false
        if !afterDot, peek() == ".", Self.isDigit(peek(1)) {
            isFloat = true
            text += "."
            advance()
            readDigits()
        }
        if let e = peek(), e == "e" || e == "E",
           Self.isDigit(peek(1)) || ((peek(1) == "+" || peek(1) == "-") && Self.isDigit(peek(2))) {
            isFloat = true
            text += "e"
            advance()
            if let sign = peek(), sign == "+" || sign == "-" {
                text.unicodeScalars.append(sign)
                advance()
            }
            readDigits()
        }
        if isFloat {
            guard let value = Double(text) else { throw makeSyntaxError("Invalid number literal", at: start) }
            return Token(kind: .float(value), location: start)
        }
        guard let value = Int(text) else {
            throw makeSyntaxError("Integer literal is too large", at: start)
        }
        return Token(kind: .integer(value), location: start)
    }

    private mutating func lexString(start: SourceLocation) throws -> Token {
        let quote = chars[index]
        advance()
        var value: [Unicode.Scalar] = []

        func hexEscape(_ length: Int) throws -> Unicode.Scalar {
            var digits = ""
            for _ in 0..<length {
                guard let next = peek(), next.properties.isASCIIHexDigit else {
                    throw makeSyntaxError("Invalid escape sequence in string", at: start)
                }
                digits.unicodeScalars.append(next)
                advance()
            }
            guard let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) else {
                throw makeSyntaxError("Invalid escape sequence in string", at: start)
            }
            return scalar
        }

        while true {
            guard let scalar = peek() else { throw makeSyntaxError("Unterminated string", at: start) }
            advance()
            if scalar == quote { break }
            guard scalar == "\\" else {
                value.append(scalar)
                continue
            }
            guard let escaped = peek() else { throw makeSyntaxError("Unterminated string", at: start) }
            advance()
            switch escaped {
            case "\\", "'", "\"": value.append(escaped)
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r": value.append("\r")
            case "a": value.append("\u{07}")
            case "b": value.append("\u{08}")
            case "f": value.append("\u{0C}")
            case "v": value.append("\u{0B}")
            case "\n": break
            case "x": value.append(try hexEscape(2))
            case "u": value.append(try hexEscape(4))
            case "U": value.append(try hexEscape(8))
            case "0"..."7":
                var code = escaped.value - 48
                for _ in 0..<2 {
                    guard let next = peek(), ("0"..."7").contains(next) else { break }
                    code = code * 8 + next.value - 48
                    advance()
                }
                value.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                value.append("\\")
                value.append(escaped)
            }
        }
        return Token(kind: .string(Py.string(value)), location: start)
    }
}
