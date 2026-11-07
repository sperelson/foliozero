import Foundation

/// Recursive-descent parser from tokens to an AST. Follows Jinja2's grammar and precedence.
struct Parser {
    /// Deepest allowed expression tree. Bounds recursion in validation and analysis.
    static let maxExpressionDepth = 100
    /// Deepest allowed nesting of blocks, brackets, calls and prefix operators, counted together.
    /// Parsing and rendering recurse once per level; 24 levels stay well inside a 512 KB thread
    /// stack even in debug builds (measured at about 10 KB per level).
    static let maxNesting = 24

    private struct BlockContext {
        var name: String
        var location: SourceLocation
        var endNames: [String]
    }

    private static let unsupportedStatements: Set<String> = [
        "macro", "call", "filter", "block", "extends", "include", "import", "from", "with",
        "autoescape", "do", "trans", "pluralize",
    ]
    private static let constantNames: Set<String> = ["true", "false", "none", "True", "False", "None"]

    private let tokens: [Token]
    private var position = 0
    private var loopDepth = 0
    private var nesting = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    // MARK: Token stream

    private var current: Token { tokens[position] }

    private func peek(_ offset: Int = 1) -> Token {
        tokens[min(position + offset, tokens.count - 1)]
    }

    @discardableResult
    private mutating func next() -> Token {
        let token = tokens[position]
        if position < tokens.count - 1 { position += 1 }
        return token
    }

    private mutating func expectOp(_ op: String) throws {
        guard current.isOp(op) else {
            throw makeSyntaxError("Expected '\(op)', got \(current.display)", at: current.location)
        }
        next()
    }

    private mutating func expectBlockEnd() throws {
        guard case .blockEnd = current.kind else {
            throw makeSyntaxError("Expected '%}', got \(current.display)", at: current.location)
        }
        next()
    }

    private mutating func expectVariableEnd() throws {
        guard case .variableEnd = current.kind else {
            throw makeSyntaxError("Expected '}}', got \(current.display)", at: current.location)
        }
        next()
    }

    private mutating func enter() throws {
        nesting += 1
        if nesting > Self.maxNesting {
            throw makeSyntaxError("Expression is nested too deeply", at: current.location)
        }
    }

    private mutating func leave() {
        nesting -= 1
    }

    private func make(_ kind: ExpressionKind, at location: SourceLocation) throws -> Expression {
        var expression = Expression(kind: kind, location: location, depth: 1)
        expression.depth = 1 + (expression.children.map(\.depth).max() ?? 0)
        if expression.depth > Self.maxExpressionDepth {
            throw makeSyntaxError("Expression is nested too deeply", at: location)
        }
        return expression
    }

    // MARK: Statements

    mutating func parseTemplate() throws -> [Node] {
        try parseNodes(until: [], context: nil).nodes
    }

    private func quoted(_ names: [String]) -> String {
        let parts = names.map { "'\($0)'" }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " or " + parts.last!
    }

    /// Parses nodes until a block tag named in `endNames`. Leaves the stream on that name.
    private mutating func parseNodes(
        until endNames: Set<String>,
        context: BlockContext?
    ) throws -> (nodes: [Node], end: String?) {
        var nodes: [Node] = []
        while true {
            let token = current
            switch token.kind {
            case .eof:
                if let context {
                    throw makeSyntaxError(
                        "Unclosed '\(context.name)' tag; expected \(quoted(context.endNames))",
                        at: context.location
                    )
                }
                return (nodes, nil)
            case .text(let chunk):
                next()
                nodes.append(.text(chunk, token.location))
            case .variableBegin:
                next()
                let expression = try parseExpression()
                try expectVariableEnd()
                nodes.append(.output(expression))
            case .blockBegin:
                next()
                guard case .name(let name) = current.kind else {
                    throw makeSyntaxError("Expected a statement name, got \(current.display)", at: current.location)
                }
                if endNames.contains(name) { return (nodes, name) }
                if name.hasPrefix("end") || name == "elif" || name == "else" {
                    var message = "Unexpected '\(name)'"
                    if let context {
                        message += "; expected \(quoted(context.endNames)) to close the '\(context.name)' tag"
                            + " from line \(context.location.line)"
                    } else {
                        message += "; no tag is open"
                    }
                    throw makeSyntaxError(message, at: current.location)
                }
                nodes.append(try parseStatement(name, begin: token))
            default:
                throw makeSyntaxError("Unexpected \(token.display)", at: token.location)
            }
        }
    }

    private mutating func parseStatement(_ name: String, begin: Token) throws -> Node {
        let nameToken = current
        switch name {
        case "if":
            return try parseIf(begin: begin)
        case "for":
            return try parseFor(begin: begin)
        case "set":
            return try parseSet(begin: begin)
        case "break", "continue":
            next()
            guard loopDepth > 0 else {
                throw makeSyntaxError("'\(name)' outside of a loop", at: nameToken.location)
            }
            try expectBlockEnd()
            return .loopControl(isBreak: name == "break")
        default:
            if Self.unsupportedStatements.contains(name) {
                throw makeSyntaxError("The '\(name)' statement is not supported", at: nameToken.location)
            }
            throw makeSyntaxError("Unknown statement '\(name)'", at: nameToken.location)
        }
    }

    /// Parses a block body one nesting level deeper than the tag that opens it.
    private mutating func parseBody(
        until endNames: Set<String>,
        context: BlockContext
    ) throws -> (nodes: [Node], end: String?) {
        nesting += 1
        defer { nesting -= 1 }
        if nesting > Self.maxNesting {
            throw makeSyntaxError("Blocks are nested too deeply", at: context.location)
        }
        return try parseNodes(until: endNames, context: context)
    }

    private mutating func parseIf(begin: Token) throws -> Node {
        next()
        var branches: [(condition: Expression, body: [Node])] = []
        var condition = try parseExpression()
        try expectBlockEnd()
        let context = BlockContext(name: "if", location: begin.location, endNames: ["elif", "else", "endif"])
        while true {
            let (body, end) = try parseBody(until: ["elif", "else", "endif"], context: context)
            branches.append((condition, body))
            next()
            switch end {
            case "elif":
                condition = try parseExpression()
                try expectBlockEnd()
            case "else":
                try expectBlockEnd()
                let elseContext = BlockContext(name: "if", location: begin.location, endNames: ["endif"])
                let otherwise = try parseBody(until: ["endif"], context: elseContext).nodes
                next()
                try expectBlockEnd()
                return .ifBlock(branches, otherwise: otherwise)
            default:
                try expectBlockEnd()
                return .ifBlock(branches, otherwise: nil)
            }
        }
    }

    private mutating func parseFor(begin: Token) throws -> Node {
        next()
        let target = try parseAssignTarget(allowAttribute: false)
        guard current.isName("in") else {
            throw makeSyntaxError("Expected 'in', got \(current.display)", at: current.location)
        }
        next()
        let iterable = try parseTuple(allowConditional: false)
        var condition: Expression?
        if current.isName("if") {
            next()
            condition = try parseExpression()
        }
        if current.isName("recursive") {
            throw makeSyntaxError("Recursive loops are not supported", at: current.location)
        }
        try expectBlockEnd()

        loopDepth += 1
        let context = BlockContext(name: "for", location: begin.location, endNames: ["else", "endfor"])
        let (body, end) = try parseBody(until: ["else", "endfor"], context: context)
        loopDepth -= 1
        next()
        var otherwise: [Node]?
        if end == "else" {
            try expectBlockEnd()
            let elseContext = BlockContext(name: "for", location: begin.location, endNames: ["endfor"])
            otherwise = try parseBody(until: ["endfor"], context: elseContext).nodes
            next()
        }
        try expectBlockEnd()
        return .forLoop(ForLoop(
            target: target, iterable: iterable, condition: condition,
            body: body, otherwise: otherwise, location: begin.location
        ))
    }

    private mutating func parseSet(begin: Token) throws -> Node {
        next()
        let target = try parseAssignTarget(allowAttribute: true)
        if current.isOp("=") {
            next()
            let value = try parseTuple(allowConditional: true)
            try expectBlockEnd()
            return .set(target, value, begin.location)
        }
        guard case .name = target else {
            throw makeSyntaxError("Expected '=', got \(current.display)", at: current.location)
        }
        try expectBlockEnd()
        let context = BlockContext(name: "set", location: begin.location, endNames: ["endset"])
        let body = try parseBody(until: ["endset"], context: context).nodes
        next()
        try expectBlockEnd()
        return .setBlock(target, body, begin.location)
    }

    private mutating func parseAssignTarget(allowAttribute: Bool) throws -> AssignTarget {
        let parenthesized = current.isOp("(")
        if parenthesized { next() }
        var names: [String] = []
        var sawComma = false
        while true {
            guard case .name(let name) = current.kind, !Self.constantNames.contains(name) else {
                throw makeSyntaxError("Expected a variable name, got \(current.display)", at: current.location)
            }
            next()
            if allowAttribute, names.isEmpty, !parenthesized, current.isOp(".") {
                next()
                guard case .name(let attribute) = current.kind else {
                    throw makeSyntaxError("Expected an attribute name, got \(current.display)", at: current.location)
                }
                next()
                return .attribute(name, attribute)
            }
            names.append(name)
            guard current.isOp(",") else { break }
            sawComma = true
            next()
            if case .name = current.kind { continue }
            break
        }
        if parenthesized { try expectOp(")") }
        return names.count == 1 && !sawComma ? .name(names[0]) : .tuple(names)
    }

    // MARK: Expressions

    private func canStartExpression(_ token: Token) -> Bool {
        switch token.kind {
        case .name, .string, .integer, .float: true
        case .op(let op): ["(", "[", "{", "-", "+"].contains(op)
        default: false
        }
    }

    /// An expression, or a comma-separated tuple of expressions (built as a list).
    private mutating func parseTuple(allowConditional: Bool) throws -> Expression {
        let start = current.location
        let first = try parseExpression(allowConditional: allowConditional)
        guard current.isOp(",") else { return first }
        var items = [first]
        while current.isOp(",") {
            next()
            guard canStartExpression(current) else { break }
            items.append(try parseExpression(allowConditional: allowConditional))
        }
        return try make(.list(items), at: start)
    }

    mutating func parseExpression(allowConditional: Bool = true) throws -> Expression {
        try enter()
        defer { leave() }
        return allowConditional ? try parseConditional() : try parseBinary(minimumLevel: Level.or)
    }

    private mutating func parseConditional() throws -> Expression {
        var expression = try parseBinary(minimumLevel: Level.or)
        while current.isName("if") {
            let location = current.location
            next()
            let test = try parseBinary(minimumLevel: Level.or)
            var otherwise: Expression?
            if current.isName("else") {
                next()
                try enter()
                otherwise = try parseConditional()
                leave()
            }
            expression = try make(.conditional(test: test, then: expression, otherwise: otherwise), at: location)
        }
        return expression
    }

    /// Binding strength of binary operators, from loosest to tightest (Jinja2's order).
    private enum Level {
        static let or = 1
        static let and = 2
        static let not = 3
        static let compare = 4
        static let add = 5
        static let concat = 6
        static let multiply = 7
        static let power = 8
    }

    private func comparisonOperator(_ token: Token) -> ComparisonOperator? {
        switch token.kind {
        case .op(let symbol): ["==", "!=", "<", "<=", ">", ">="].contains(symbol) ? ComparisonOperator(rawValue: symbol) : nil
        case .name("in"): .in
        case .name("not") where peek().isName("in"): .notIn
        default: nil
        }
    }

    private func binaryLevel(_ token: Token) -> Int? {
        switch token.kind {
        case .name("or"): Level.or
        case .name("and"): Level.and
        case .op("+"), .op("-"): Level.add
        case .op("~"): Level.concat
        case .op("*"), .op("/"), .op("//"), .op("%"): Level.multiply
        case .op("**"): Level.power
        default: comparisonOperator(token) != nil ? Level.compare : nil
        }
    }

    /// Precedence climbing over Jinja2's binary operators. One frame per operand keeps deep
    /// nesting cheap on the stack.
    private mutating func parseBinary(minimumLevel: Int) throws -> Expression {
        var left: Expression
        if minimumLevel <= Level.not, current.isName("not") {
            let location = next().location
            try enter()
            let operand = try parseBinary(minimumLevel: Level.not)
            leave()
            left = try make(.not(operand), at: location)
        } else {
            left = try parseUnary()
        }
        while let level = binaryLevel(current), level >= minimumLevel {
            left = try parseOperation(left: left, level: level)
        }
        return left
    }

    private mutating func parseOperation(left: Expression, level: Int) throws -> Expression {
        let location = current.location
        switch level {
        case Level.compare:
            var operations: [(op: ComparisonOperator, operand: Expression)] = []
            while let op = comparisonOperator(current) {
                next()
                if op == .notIn { next() }
                operations.append((op, try parseBinary(minimumLevel: Level.add)))
            }
            return try make(.compare(left, operations), at: location)
        case Level.concat:
            var parts = [left]
            while current.isOp("~") {
                next()
                parts.append(try parseBinary(minimumLevel: Level.multiply))
            }
            return try make(.concat(parts), at: location)
        default:
            let token = next()
            let right = try parseBinary(minimumLevel: level + 1)
            let kind: ExpressionKind = switch token.kind {
            case .name("or"): .or(left, right)
            case .name("and"): .and(left, right)
            case .op("+"): .binary(.add, left, right)
            case .op("-"): .binary(.subtract, left, right)
            case .op("*"): .binary(.multiply, left, right)
            case .op("/"): .binary(.divide, left, right)
            case .op("//"): .binary(.floorDivide, left, right)
            case .op("%"): .binary(.modulo, left, right)
            default: .binary(.power, left, right)
            }
            return try make(kind, at: location)
        }
    }

    private mutating func parseUnary(withFilter: Bool = true) throws -> Expression {
        let token = current
        var node: Expression
        if token.isOp("-") || token.isOp("+") {
            next()
            try enter()
            let operand = try parseUnary(withFilter: false)
            leave()
            node = try make(.unary(token.isOp("-") ? .negate : .positive, operand), at: token.location)
        } else {
            node = try parsePrimary()
        }
        node = try parsePostfix(node)
        if withFilter { node = try parseFilterExpression(node) }
        return node
    }

    private mutating func parsePrimary() throws -> Expression {
        let token = current
        switch token.kind {
        case .name(let name):
            next()
            switch name {
            case "true", "True": return try make(.literal(.bool(true)), at: token.location)
            case "false", "False": return try make(.literal(.bool(false)), at: token.location)
            case "none", "None": return try make(.literal(.none), at: token.location)
            default: return try make(.name(name), at: token.location)
            }
        case .string(var value):
            next()
            while case .string(let more) = current.kind {
                value += more
                next()
            }
            return try make(.literal(.string(value)), at: token.location)
        case .integer(let value):
            next()
            return try make(.literal(.int(value)), at: token.location)
        case .float(let value):
            next()
            return try make(.literal(.double(value)), at: token.location)
        case .op("("):
            return try parseParenthesized()
        case .op("["):
            return try parseListLiteral()
        case .op("{"):
            return try parseDictLiteral()
        default:
            throw makeSyntaxError("Unexpected \(token.display); expected an expression", at: token.location)
        }
    }

    private mutating func parseParenthesized() throws -> Expression {
        let location = next().location
        if current.isOp(")") {
            next()
            return try make(.list([]), at: location)
        }
        let inner = try parseTuple(allowConditional: true)
        try expectOp(")")
        return inner
    }

    private mutating func parseListLiteral() throws -> Expression {
        let location = next().location
        var items: [Expression] = []
        while !current.isOp("]") {
            if !items.isEmpty {
                try expectOp(",")
                if current.isOp("]") { break }
            }
            items.append(try parseExpression())
        }
        next()
        return try make(.list(items), at: location)
    }

    private mutating func parseDictLiteral() throws -> Expression {
        let location = next().location
        var pairs: [(key: Expression, value: Expression)] = []
        while !current.isOp("}") {
            if !pairs.isEmpty {
                try expectOp(",")
                if current.isOp("}") { break }
            }
            let key = try parseExpression()
            try expectOp(":")
            pairs.append((key, try parseExpression()))
        }
        next()
        return try make(.dict(pairs), at: location)
    }

    private mutating func parsePostfix(_ base: Expression) throws -> Expression {
        var node = base
        while true {
            if current.isOp(".") {
                next()
                switch current.kind {
                case .name(let attribute):
                    next()
                    node = try make(.attribute(node, attribute), at: node.location)
                case .integer(let index):
                    let indexLocation = next().location
                    node = try make(.item(node, try make(.literal(.int(index)), at: indexLocation)), at: node.location)
                default:
                    throw makeSyntaxError("Expected an attribute name after '.', got \(current.display)", at: current.location)
                }
            } else if current.isOp("[") {
                node = try parseSubscript(node)
            } else if current.isOp("(") {
                node = try make(.call(node, try parseCallArguments()), at: node.location)
            } else {
                return node
            }
        }
    }

    private mutating func parseSubscript(_ base: Expression) throws -> Expression {
        next()
        var start: Expression?
        var stop: Expression?
        var step: Expression?
        var isSlice = false
        if !current.isOp(":") { start = try parseExpression() }
        if current.isOp(":") {
            isSlice = true
            next()
            if !current.isOp("]") && !current.isOp(":") { stop = try parseExpression() }
            if current.isOp(":") {
                next()
                if !current.isOp("]") { step = try parseExpression() }
            }
        }
        try expectOp("]")
        if isSlice {
            return try make(.slice(base, start: start, stop: stop, step: step), at: base.location)
        }
        return try make(.item(base, start!), at: base.location)
    }

    private mutating func parseCallArguments() throws -> Arguments {
        try expectOp("(")
        var arguments = Arguments()
        while !current.isOp(")") {
            if !arguments.positional.isEmpty || !arguments.keyword.isEmpty {
                try expectOp(",")
                if current.isOp(")") { break }
            }
            if case .name(let name) = current.kind, peek().isOp("=") {
                next()
                next()
                arguments.keyword.append(KeywordArgument(name: name, value: try parseExpression()))
            } else {
                if !arguments.keyword.isEmpty {
                    throw makeSyntaxError("Positional argument follows keyword argument", at: current.location)
                }
                arguments.positional.append(try parseExpression())
            }
        }
        next()
        return arguments
    }

    private mutating func parseFilterExpression(_ base: Expression) throws -> Expression {
        var node = base
        while true {
            if current.isOp("|") {
                node = try parseFilter(node)
            } else if current.isName("is") {
                node = try parseTest(node)
            } else if current.isOp("(") {
                node = try make(.call(node, try parseCallArguments()), at: node.location)
            } else {
                return node
            }
        }
    }

    private mutating func parseDottedName() -> String? {
        guard case .name(var name) = current.kind else { return nil }
        next()
        while current.isOp("."), case .name(let more) = peek().kind {
            next()
            next()
            name += "." + more
        }
        return name
    }

    private mutating func parseFilter(_ base: Expression) throws -> Expression {
        next()
        let location = current.location
        guard let name = parseDottedName() else {
            throw makeSyntaxError("Expected a filter name after '|', got \(current.display)", at: location)
        }
        let arguments = current.isOp("(") ? try parseCallArguments() : Arguments()
        return try make(.filter(base, name: name, arguments), at: location)
    }

    private mutating func parseTest(_ base: Expression) throws -> Expression {
        next()
        var negated = false
        if current.isName("not") {
            next()
            negated = true
        }
        let location = current.location
        guard let name = parseDottedName() else {
            throw makeSyntaxError("Expected a test name after 'is', got \(current.display)", at: location)
        }
        var arguments = Arguments()
        if current.isOp("(") {
            arguments = try parseCallArguments()
        } else if startsBareTestArgument(current) {
            if current.isName("is") {
                throw makeSyntaxError("Tests cannot be chained with 'is'", at: current.location)
            }
            arguments.positional = [try parsePostfix(try parsePrimary())]
        }
        return try make(.test(base, name: name, arguments, negated: negated), at: location)
    }

    private func startsBareTestArgument(_ token: Token) -> Bool {
        switch token.kind {
        case .name(let name): !["else", "or", "and", "if", "not", "in"].contains(name)
        case .string, .integer, .float: true
        case .op(let op): op == "[" || op == "{"
        default: false
        }
    }
}
