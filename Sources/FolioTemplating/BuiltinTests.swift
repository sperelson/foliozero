import Foundation

/// One test application: `value is name(args...)`.
struct TestCall {
    var name: String
    var value: TemplateValue
    var args: [TemplateValue]
    var kwargs: [String: TemplateValue]
    var environment: TemplateEnvironment

    func argument(_ parameter: String) throws -> TemplateValue {
        try ArgumentBinder(owner: "Test '\(name)'", args: args, kwargs: kwargs).bind([(parameter, nil)])[0]
    }

    func noArguments() throws {
        _ = try ArgumentBinder(owner: "Test '\(name)'", args: args, kwargs: kwargs).bind([])
    }
}

/// Jinja2's built-in tests.
enum BuiltinTests {
    typealias Implementation = @Sendable (TestCall) throws -> Bool

    /// Tests that only inspect the type, so they never fail on undefined values.
    static let typeTests: Set<String> = [
        "defined", "undefined", "none", "boolean", "false", "true", "integer", "float", "number",
        "string", "mapping", "iterable", "sequence", "callable", "sameas", "escaped", "filter", "test",
    ]

    /// Tests that compare for equality; undefined is allowed unless the environment is strict.
    static let equalityTests: Set<String> = ["eq", "equalto", "==", "ne", "!=", "in", "lower", "upper"]

    static let all: [String: Implementation] = [
        "defined": { try $0.noArguments(); return !$0.value.isUndefined },
        "undefined": { try $0.noArguments(); return $0.value.isUndefined },
        "none": { try $0.noArguments(); if case .none = $0.value { return true }; return false },
        "boolean": { try $0.noArguments(); if case .bool = $0.value { return true }; return false },
        "true": { try $0.noArguments(); if case .bool(true) = $0.value { return true }; return false },
        "false": { try $0.noArguments(); if case .bool(false) = $0.value { return true }; return false },
        "integer": { try $0.noArguments(); if case .int = $0.value { return true }; return false },
        "float": { try $0.noArguments(); if case .double = $0.value { return true }; return false },
        "number": { try $0.noArguments(); return Py.number($0.value) != nil },
        "string": { try $0.noArguments(); if case .string = $0.value.plain { return true }; return false },
        "mapping": { try $0.noArguments(); if case .dict = $0.value { return true }; return false },
        "iterable": { call in
            try call.noArguments()
            switch call.value {
            case .string, .array, .dict, .undefined: return true
            default: return false
            }
        },
        "sequence": { call in
            try call.noArguments()
            switch call.value {
            case .string, .array, .dict, .undefined: return true
            default: return false
            }
        },
        "callable": { try $0.noArguments(); return false },
        "escaped": { try $0.noArguments(); return false },
        "sameas": { call in
            let other = try call.argument("other")
            return Py.typeName(call.value) == Py.typeName(other) && Py.equals(call.value, other)
        },
        "lower": { try $0.noArguments(); return PyString.hasOnlyCase(Py.str($0.value), lower: true) },
        "upper": { try $0.noArguments(); return PyString.hasOnlyCase(Py.str($0.value), lower: false) },
        "even": { call in
            try call.noArguments()
            return Py.equals(try Py.modulo(call.value, 2, call.environment.limits), 0)
        },
        "odd": { call in
            try call.noArguments()
            return !Py.equals(try Py.modulo(call.value, 2, call.environment.limits), 0)
        },
        "divisibleby": { call in
            let divisor = try call.argument("num")
            return Py.equals(try Py.modulo(call.value, divisor, call.environment.limits), 0)
        },
        "eq": equal, "equalto": equal, "==": equal,
        "ne": { !(try equal($0)) }, "!=": { !(try equal($0)) },
        "lt": { try Py.order(.less, $0.value, $0.argument("other")) },
        "lessthan": { try Py.order(.less, $0.value, $0.argument("other")) },
        "<": { try Py.order(.less, $0.value, $0.argument("other")) },
        "le": { try Py.order(.lessOrEqual, $0.value, $0.argument("other")) },
        "<=": { try Py.order(.lessOrEqual, $0.value, $0.argument("other")) },
        "gt": { try Py.order(.greater, $0.value, $0.argument("other")) },
        "greaterthan": { try Py.order(.greater, $0.value, $0.argument("other")) },
        ">": { try Py.order(.greater, $0.value, $0.argument("other")) },
        "ge": { try Py.order(.greaterOrEqual, $0.value, $0.argument("other")) },
        ">=": { try Py.order(.greaterOrEqual, $0.value, $0.argument("other")) },
        "in": { try Py.contains($0.argument("seq"), $0.value) },
        "filter": { $0.environment.hasFilter(Py.str($0.value)) },
        "test": { all[Py.str($0.value)] != nil },
    ]

    private static func equal(_ call: TestCall) throws -> Bool {
        Py.equals(call.value, try call.argument("other"))
    }
}
