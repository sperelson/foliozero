import Foundation

enum BinaryOperator: String, Sendable {
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case floorDivide = "//"
    case modulo = "%"
    case power = "**"
}

enum UnaryOperator: Sendable {
    case negate, positive
}

/// A keyword argument in a call, filter or test.
struct KeywordArgument: Sendable {
    var name: String
    var value: Expression
}

struct Arguments: Sendable {
    var positional: [Expression] = []
    var keyword: [KeywordArgument] = []

    var all: [Expression] { positional + keyword.map(\.value) }
}

indirect enum ExpressionKind: Sendable {
    case literal(TemplateValue)
    case name(String)
    case list([Expression])
    case dict([(key: Expression, value: Expression)])
    case attribute(Expression, String)
    case item(Expression, Expression)
    case slice(Expression, start: Expression?, stop: Expression?, step: Expression?)
    case call(Expression, Arguments)
    case filter(Expression, name: String, Arguments)
    case test(Expression, name: String, Arguments, negated: Bool)
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
    case concat([Expression])
    case and(Expression, Expression)
    case or(Expression, Expression)
    case not(Expression)
    case compare(Expression, [(op: ComparisonOperator, operand: Expression)])
    case conditional(test: Expression, then: Expression, otherwise: Expression?)
}

struct Expression: Sendable {
    var kind: ExpressionKind
    /// Where errors about this expression point.
    var location: SourceLocation
    /// Height of the expression tree; bounded so evaluation cannot overflow the stack.
    var depth: Int

    var children: [Expression] {
        switch kind {
        case .literal, .name: []
        case .list(let items): items
        case .dict(let pairs): pairs.flatMap { [$0.key, $0.value] }
        case .attribute(let base, _): [base]
        case .item(let base, let index): [base, index]
        case let .slice(base, start, stop, step): [base] + [start, stop, step].compactMap { $0 }
        case let .call(callee, arguments): [callee] + arguments.all
        case let .filter(base, _, arguments): [base] + arguments.all
        case let .test(base, _, arguments, _): [base] + arguments.all
        case .unary(_, let operand): [operand]
        case let .binary(_, left, right): [left, right]
        case .concat(let parts): parts
        case let .and(left, right), let .or(left, right): [left, right]
        case .not(let operand): [operand]
        case let .compare(first, rest): [first] + rest.map(\.operand)
        case let .conditional(test, then, otherwise): [test, then] + [otherwise].compactMap { $0 }
        }
    }
}

/// The left side of `set` or the target of `for`.
enum AssignTarget: Sendable {
    case name(String)
    case tuple([String])
    /// `set ns.attr = value`
    case attribute(String, String)

    var names: [String] {
        switch self {
        case .name(let name): [name]
        case .tuple(let names): names
        case .attribute(let name, _): [name]
        }
    }
}

struct ForLoop: Sendable {
    var target: AssignTarget
    var iterable: Expression
    var condition: Expression?
    var body: [Node]
    var otherwise: [Node]?
    var location: SourceLocation
}

indirect enum Node: Sendable {
    case text(TextChunk, SourceLocation)
    case output(Expression)
    case ifBlock([(condition: Expression, body: [Node])], otherwise: [Node]?)
    case forLoop(ForLoop)
    case set(AssignTarget, Expression, SourceLocation)
    case setBlock(AssignTarget, [Node], SourceLocation)
    case loopControl(isBreak: Bool)
}
