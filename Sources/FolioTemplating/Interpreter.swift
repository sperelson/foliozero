import Foundation

/// Executes a parsed template. One instance renders once; it is not shared between threads.
final class Interpreter {
    private enum Flow {
        case normal, breakLoop, continueLoop
    }

    private let environment: TemplateEnvironment
    private let context: [String: TemplateValue]
    private let limits: ValueLimits
    private let whitespace: WhitespaceOptions
    private var scopes: [[String: TemplateValue]] = [[:]]
    private var output = ""
    private var outputBytes = 0
    private var iterations = 0
    /// Bytes of strings produced by filters, methods and operators during this render.
    private var producedBytes = 0
    private let producedBytesLimit: Int

    init(environment: TemplateEnvironment, context: [String: TemplateValue]) {
        self.environment = environment
        self.context = context
        limits = environment.limits
        whitespace = environment.whitespace
        let (budget, overflow) = environment.maxOutputLength.multipliedReportingOverflow(by: 1024)
        producedBytesLimit = overflow ? .max : budget
    }

    /// Counts the strings in a computed value against the per-render budget.
    private func charge(_ value: TemplateValue, at location: SourceLocation) throws -> TemplateValue {
        var bytes = 0
        switch value {
        case .string(let s): bytes = s.utf8.count
        case .array(let items):
            for item in items {
                if case .string(let s) = item { bytes += s.utf8.count } else { bytes += 8 }
            }
        case .dict(let dict):
            for item in dict.values {
                if case .string(let s) = item { bytes += s.utf8.count } else { bytes += 8 }
            }
        default:
            return value
        }
        producedBytes += bytes
        if producedBytes > producedBytesLimit {
            throw RuntimeFailure(
                "Template produced more than \(producedBytesLimit) bytes of intermediate data", at: location
            )
        }
        return value
    }

    /// Checks a newly built list or dict for depth and counts it against the budget.
    private func built(_ value: TemplateValue, at location: SourceLocation) throws -> TemplateValue {
        try located(location) { try Py.checkDepth(value) }
        return try charge(value, at: location)
    }

    func render(_ nodes: [Node]) throws -> String {
        do {
            _ = try execute(nodes)
            return output
        } catch let failure as RuntimeFailure {
            throw TemplateError.runtime(failure.formatted)
        }
    }

    // MARK: Statements

    private func write(_ text: String, at location: SourceLocation) throws {
        outputBytes += text.utf8.count
        if outputBytes > environment.maxOutputLength {
            throw RuntimeFailure("Output exceeds the maximum length of \(environment.maxOutputLength) bytes", at: location)
        }
        output += text
    }

    private func execute(_ nodes: [Node]) throws -> Flow {
        for node in nodes {
            let flow = try execute(node)
            if flow != .normal { return flow }
        }
        return .normal
    }

    private func execute(_ node: Node) throws -> Flow {
        switch node {
        case let .text(chunk, location):
            try write(chunk.rendered(whitespace), at: location)
        case .output(let expression):
            let value = try evaluate(expression)
            try write(try text(of: value, expression), at: expression.location)
        case let .ifBlock(branches, otherwise):
            for branch in branches {
                if try truthy(evaluate(branch.condition), branch.condition) { return try execute(branch.body) }
            }
            if let otherwise { return try execute(otherwise) }
        case .forLoop(let loop):
            try executeFor(loop)
        case let .set(target, expression, location):
            try assign(target, try evaluate(expression), at: location)
        case let .setBlock(target, body, location):
            let savedOutput = output
            let savedBytes = outputBytes
            output = ""
            outputBytes = 0
            let flow: Flow
            do {
                flow = try execute(body)
            } catch {
                output = savedOutput
                outputBytes = savedBytes
                throw error
            }
            let captured = output
            output = savedOutput
            outputBytes = savedBytes
            try assign(target, .string(captured), at: location)
            return flow
        case .loopControl(let isBreak):
            return isBreak ? .breakLoop : .continueLoop
        }
        return .normal
    }

    private func countIteration(at location: SourceLocation) throws {
        iterations += 1
        if iterations > environment.maxLoopIterations {
            throw RuntimeFailure(
                "Template exceeded the limit of \(environment.maxLoopIterations) loop iterations", at: location
            )
        }
    }

    private func executeFor(_ loop: ForLoop) throws {
        let iterable = try evaluate(loop.iterable)
        try requireDefined(iterable, loop.iterable)
        var items = try located(loop.iterable.location) { try Py.iterate(iterable) }

        scopes.append([:])
        defer { scopes.removeLast() }

        if let condition = loop.condition {
            var kept: [TemplateValue] = []
            for item in items {
                try countIteration(at: loop.location)
                try bind(loop.target, item, at: loop.location)
                if try truthy(evaluate(condition), condition) { kept.append(item) }
            }
            items = kept
        }

        guard !items.isEmpty else {
            if let otherwise = loop.otherwise { _ = try execute(otherwise) }
            return
        }

        let length = items.count
        for (index, item) in items.enumerated() {
            try countIteration(at: loop.location)
            try bind(loop.target, item, at: loop.location)
            var info: [String: TemplateValue] = [
                "index": .int(index + 1),
                "index0": .int(index),
                "revindex": .int(length - index),
                "revindex0": .int(length - index - 1),
                "first": .bool(index == 0),
                "last": .bool(index == length - 1),
                "length": .int(length),
                "depth": 1,
                "depth0": 0,
            ]
            if index > 0 { info["previtem"] = items[index - 1] }
            if index + 1 < length { info["nextitem"] = items[index + 1] }
            scopes[scopes.count - 1]["loop"] = .dict(info)
            if try execute(loop.body) == .breakLoop { break }
        }
    }

    private func bind(_ target: AssignTarget, _ value: TemplateValue, at location: SourceLocation) throws {
        switch target {
        case .name(let name):
            scopes[scopes.count - 1][name] = value
        case .tuple(let names):
            let items = try located(location) { try Py.iterate(value) }
            if items.count < names.count {
                throw RuntimeFailure(
                    "not enough values to unpack (expected \(names.count), got \(items.count))", at: location
                )
            }
            if items.count > names.count {
                throw RuntimeFailure("too many values to unpack (expected \(names.count))", at: location)
            }
            for (name, item) in zip(names, items) {
                scopes[scopes.count - 1][name] = item
            }
        case .attribute:
            try assign(target, value, at: location)
        }
    }

    private func assign(_ target: AssignTarget, _ value: TemplateValue, at location: SourceLocation) throws {
        guard case let .attribute(name, attribute) = target else {
            try bind(target, value, at: location)
            return
        }
        let scopeIndex = scopes.lastIndex { $0[name] != nil }
        let current = scopeIndex.flatMap { scopes[$0][name] } ?? context[name] ?? .undefined
        guard case .dict(var dict) = current else {
            throw RuntimeFailure(
                "Cannot assign attribute '\(attribute)' on '\(name)', which is \(Py.typeName(current)), not a namespace",
                at: location
            )
        }
        dict[attribute] = value
        try located(location) { try Py.checkDepth(.dict(dict)) }
        scopes[scopeIndex ?? 0][name] = .dict(dict)
    }

    // MARK: Undefined handling

    private func describe(_ expression: Expression) -> String {
        switch expression.kind {
        case .name(let name): return name
        case let .attribute(base, name): return "\(describe(base)).\(name)"
        case let .item(base, index):
            if case .literal(let key) = index.kind { return "\(describe(base))[\(Py.repr(key))]" }
            return "\(describe(base))[...]"
        case let .call(callee, _): return "\(describe(callee))()"
        case let .filter(base, name, _): return "\(describe(base)) | \(name)"
        case .literal(let value): return Py.repr(value)
        default: return "expression"
        }
    }

    private func undefinedError(_ expression: Expression) -> RuntimeFailure {
        RuntimeFailure("'\(describe(expression))' is undefined", at: expression.location)
    }

    /// Throws when the value is undefined and the environment is strict.
    private func requireDefined(_ value: TemplateValue, _ expression: Expression) throws {
        if environment.strictUndefined, value.isUndefined { throw undefinedError(expression) }
    }

    /// Throws when the value is undefined, in any mode (arithmetic, ordering, calls).
    private func requireValue(_ value: TemplateValue, _ expression: Expression) throws {
        if value.isUndefined { throw undefinedError(expression) }
    }

    private func truthy(_ value: TemplateValue, _ expression: Expression) throws -> Bool {
        try requireDefined(value, expression)
        return Py.truthy(value)
    }

    private func text(of value: TemplateValue, _ expression: Expression) throws -> String {
        try requireDefined(value, expression)
        return Py.str(value)
    }

    /// Runs `body`, attaching `location` to errors that do not carry one yet.
    private func located<T>(_ location: SourceLocation, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch var failure as RuntimeFailure {
            if failure.location == nil { failure.location = location }
            throw failure
        }
    }

    // MARK: Expressions

    private func lookup(_ name: String) -> TemplateValue {
        for scope in scopes.reversed() {
            if let value = scope[name] { return value }
        }
        return context[name] ?? .undefined
    }

    private func isBound(_ name: String) -> Bool {
        scopes.contains { $0[name] != nil } || context[name] != nil
    }

    /// Evaluates an expression. Left-deep chains (`a + b + c`, `x | f | g`, `a.b.c`) are walked
    /// iteratively, so only right operands and nested brackets use the call stack.
    private func evaluate(_ expression: Expression) throws -> TemplateValue {
        var spine: [Expression] = []
        var node = expression
        while let base = Self.leftOperand(of: node) {
            spine.append(node)
            node = base
        }
        var value = try evaluateLeaf(node)
        while let parent = spine.popLast() {
            value = try apply(parent, to: value)
        }
        return value
    }

    /// The operand evaluated first, for expressions that `apply` can finish from its value.
    private static func leftOperand(of expression: Expression) -> Expression? {
        switch expression.kind {
        case let .binary(_, left, _), let .and(left, _), let .or(left, _): left
        case let .attribute(base, _), let .item(base, _): base
        case let .slice(base, _, _, _): base
        case let .filter(base, _, _), let .test(base, _, _, _): base
        case let .call(callee, _):
            if case let .attribute(base, _) = callee.kind { base } else { nil }
        default: nil
        }
    }

    private func apply(_ expression: Expression, to value: TemplateValue) throws -> TemplateValue {
        switch expression.kind {
        case let .binary(op, left, right):
            return try charge(try applyBinary(op, value, left, right, at: expression.location), at: expression.location)
        case let .and(left, right):
            return try truthy(value, left) ? try evaluate(right) : value
        case let .or(left, right):
            return try truthy(value, left) ? value : try evaluate(right)
        case let .attribute(base, name):
            try requireDefined(value, base)
            return ValueAccess.attribute(value, name)
        case let .item(base, index):
            try requireDefined(value, base)
            return ValueAccess.item(value, try evaluate(index))
        case let .slice(base, start, stop, step):
            try requireDefined(value, base)
            return try applySlice(value, start, stop, step, at: expression.location)
        case let .filter(base, name, arguments):
            return try built(try applyFilter(value, base, name, arguments, at: expression.location), at: expression.location)
        case let .test(base, name, arguments, negated):
            let result = try applyTest(value, base, name, arguments, at: expression.location)
            return .bool(negated ? !result : result)
        case let .call(callee, arguments):
            guard case let .attribute(base, method) = callee.kind else { return value }
            return try built(try applyMethod(value, base, method, arguments, at: expression.location), at: expression.location)
        default:
            return value
        }
    }

    private func evaluateLeaf(_ expression: Expression) throws -> TemplateValue {
        switch expression.kind {
        case .literal(let value):
            return value
        case .name(let name):
            return lookup(name)
        case .list(let items):
            return try built(.array(try items.map(evaluate)), at: expression.location)
        case .dict(let pairs):
            return try built(try evaluateDict(pairs), at: expression.location)
        case let .call(callee, arguments):
            return try built(try evaluateCall(callee, arguments, at: expression.location), at: expression.location)
        case let .unary(op, operand):
            return try evaluateUnary(op, operand, at: expression.location)
        case .concat(let parts):
            return try charge(try evaluateConcat(parts, at: expression.location), at: expression.location)
        case .not(let operand):
            return .bool(!(try truthy(evaluate(operand), operand)))
        case let .compare(first, operations):
            return try evaluateCompare(first, operations, at: expression.location)
        case let .conditional(test, then, otherwise):
            if try truthy(evaluate(test), test) { return try evaluate(then) }
            return try otherwise.map(evaluate) ?? .undefined
        default:
            // Chain expressions are handled by `evaluate` and `apply`.
            return try evaluate(expression)
        }
    }

    private func evaluateDict(_ pairs: [(key: Expression, value: Expression)]) throws -> TemplateValue {
        var dict: [String: TemplateValue] = [:]
        for pair in pairs {
            guard case .string(let key) = try evaluate(pair.key).plain else {
                throw RuntimeFailure("Dictionary keys must be strings", at: pair.key.location)
            }
            dict[key] = try evaluate(pair.value)
        }
        return .dict(dict)
    }

    private func evaluateUnary(_ op: UnaryOperator, _ operandExpression: Expression, at location: SourceLocation) throws -> TemplateValue {
        let operand = try evaluate(operandExpression)
        try requireValue(operand, operandExpression)
        return try located(location) {
            op == .negate ? try Py.negate(operand) : try Py.positive(operand)
        }
    }

    private func applyBinary(
        _ op: BinaryOperator,
        _ left: TemplateValue,
        _ leftExpression: Expression,
        _ rightExpression: Expression,
        at location: SourceLocation
    ) throws -> TemplateValue {
        try requireValue(left, leftExpression)
        let right = try evaluate(rightExpression)
        try requireValue(right, rightExpression)
        return try located(location) {
            switch op {
            case .add: try Py.add(left, right, limits)
            case .subtract: try Py.subtract(left, right)
            case .multiply: try Py.multiply(left, right, limits)
            case .divide: try Py.divide(left, right)
            case .floorDivide: try Py.floorDivide(left, right)
            case .modulo: try Py.modulo(left, right, limits)
            case .power: try Py.power(left, right)
            }
        }
    }

    private func applySlice(
        _ value: TemplateValue,
        _ start: Expression?, _ stop: Expression?, _ step: Expression?,
        at location: SourceLocation
    ) throws -> TemplateValue {
        let bounds = try [start, stop, step].map { try $0.map(evaluate) ?? .none }
        return try located(location) {
            try ValueAccess.slice(value, start: bounds[0], stop: bounds[1], step: bounds[2])
        }
    }

    private func evaluateConcat(_ parts: [Expression], at location: SourceLocation) throws -> TemplateValue {
        var result = ""
        for part in parts {
            result += try text(of: try evaluate(part), part)
            try located(location) { try limits.checkStringLength(result.utf8.count) }
        }
        return .string(result)
    }

    private func evaluateCompare(
        _ firstExpression: Expression,
        _ operations: [(op: ComparisonOperator, operand: Expression)],
        at location: SourceLocation
    ) throws -> TemplateValue {
        var left = try evaluate(firstExpression)
        var leftExpression = firstExpression
        for (op, rightExpression) in operations {
            let right = try evaluate(rightExpression)
            if !(try compare(op, left, leftExpression, right, rightExpression, at: location)) {
                return .bool(false)
            }
            left = right
            leftExpression = rightExpression
        }
        return .bool(true)
    }

    private func compare(
        _ op: ComparisonOperator,
        _ left: TemplateValue, _ leftExpression: Expression,
        _ right: TemplateValue, _ rightExpression: Expression,
        at location: SourceLocation
    ) throws -> Bool {
        switch op {
        case .equal, .notEqual:
            try requireDefined(left, leftExpression)
            try requireDefined(right, rightExpression)
            return Py.equals(left, right) == (op == .equal)
        case .in, .notIn:
            try requireDefined(left, leftExpression)
            try requireDefined(right, rightExpression)
            return try located(location) { try Py.contains(right, left) } == (op == .in)
        default:
            try requireValue(left, leftExpression)
            try requireValue(right, rightExpression)
            return try located(location) { try Py.order(op, left, right) }
        }
    }

    private func evaluateArguments(_ arguments: Arguments) throws -> ([TemplateValue], [String: TemplateValue]) {
        let positional = try arguments.positional.map(evaluate)
        var keyword: [String: TemplateValue] = [:]
        for argument in arguments.keyword {
            if keyword[argument.name] != nil {
                throw RuntimeFailure("Keyword argument '\(argument.name)' repeated", at: argument.value.location)
            }
            keyword[argument.name] = try evaluate(argument.value)
        }
        return (positional, keyword)
    }

    private func applyMethod(
        _ base: TemplateValue,
        _ baseExpression: Expression,
        _ method: String,
        _ arguments: Arguments,
        at location: SourceLocation
    ) throws -> TemplateValue {
        try requireValue(base, baseExpression)
        let (args, kwargs) = try evaluateArguments(arguments)
        return try located(location) {
            try ValueMethods.call(base, method, args: args, kwargs: kwargs, environment: environment)
        }
    }

    private func evaluateCall(_ callee: Expression, _ arguments: Arguments, at location: SourceLocation) throws -> TemplateValue {
        if case .name(let name) = callee.kind, !isBound(name), ValueMethods.globalNames.contains(name) {
            let (args, kwargs) = try evaluateArguments(arguments)
            return try located(location) {
                try ValueMethods.callGlobal(name, args: args, kwargs: kwargs, environment: environment) ?? .undefined
            }
        }
        let value = try evaluate(callee)
        try requireValue(value, callee)
        throw RuntimeFailure("'\(Py.typeName(value))' object is not callable", at: location)
    }

    private func applyFilter(
        _ value: TemplateValue,
        _ baseExpression: Expression,
        _ name: String,
        _ arguments: Arguments,
        at location: SourceLocation
    ) throws -> TemplateValue {
        guard let filter = environment.filters[name] else {
            throw makeSyntaxError("No filter named '\(name)'", at: location)
        }
        if name != "default" && name != "d" { try requireDefined(value, baseExpression) }
        let (args, kwargs) = try evaluateArguments(arguments)
        let call = FilterCall(name: name, value: value, args: args, kwargs: kwargs, environment: environment)
        do {
            return try filter(call)
        } catch var failure as RuntimeFailure {
            if failure.location == nil { failure.location = location }
            throw failure
        } catch TemplateError.runtime(let message) {
            throw RuntimeFailure(message, at: location)
        } catch let error as TemplateError {
            throw error
        } catch {
            throw RuntimeFailure("Filter '\(name)' failed: \(error)", at: location)
        }
    }

    private func applyTest(
        _ value: TemplateValue,
        _ baseExpression: Expression,
        _ name: String,
        _ arguments: Arguments,
        at location: SourceLocation
    ) throws -> Bool {
        guard let test = BuiltinTests.all[name] else {
            throw makeSyntaxError("No test named '\(name)'", at: location)
        }
        if !BuiltinTests.typeTests.contains(name) {
            if BuiltinTests.equalityTests.contains(name) {
                try requireDefined(value, baseExpression)
            } else {
                try requireValue(value, baseExpression)
            }
        }
        let (args, kwargs) = try evaluateArguments(arguments)
        return try located(location) {
            try test(TestCall(name: name, value: value, args: args, kwargs: kwargs, environment: environment))
        }
    }
}
