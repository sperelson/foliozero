import Foundation
import Testing
@testable import FolioTemplating

@Suite("Errors")
struct ErrorTests {
    @Test(arguments: [
        // source, line, column, message fragment
        ("{{ 1 + }}", 1, 8, "Unexpected '}}'"),
        ("{{ 1 2 }}", 1, 6, "Expected '}}'"),
        ("line1\n{% if x %}\nfoo", 2, 1, "Unclosed 'if'"),
        ("{% for x in y %}{% endif %}", 1, 20, "Unexpected 'endif'"),
        ("{% endif %}", 1, 4, "Unexpected 'endif'"),
        ("{{ 'abc }}", 1, 4, "Unterminated string"),
        ("{% for x in %}{% endfor %}", 1, 13, "Unexpected '%}'"),
        ("{% for x of y %}{% endfor %}", 1, 10, "Expected 'in'"),
        ("{{ foo( }}", 1, 9, "Unexpected '}'; expected ')'"),
        ("{% frobnicate %}", 1, 4, "Unknown statement 'frobnicate'"),
        ("{% include 'x' %}", 1, 4, "not supported"),
        ("{{ x | }}", 1, 8, "Expected a filter name"),
        ("a\n  {{ x", 2, 3, "never closed"),
        ("{# never closed", 1, 1, "never closed"),
        ("{% raw %} abc", 1, 1, "endraw"),
        ("{% break %}", 1, 4, "outside of a loop"),
        ("{{ x ! y }}", 1, 6, "Unexpected character '!'"),
        ("{{ (1 + 2 }}", 1, 11, "Unexpected '}'"),
        ("{{ [1, 2) }}", 1, 9, "Unexpected ')'"),
        ("{% if x %}{% else %}{% elif y %}{% endif %}", 1, 24, "Unexpected 'elif'"),
        ("{{ 99999999999999999999 }}", 1, 4, "too large"),
        ("{% set 1 = 2 %}", 1, 8, "Expected a variable name"),
        ("{{ }}", 1, 4, "expected an expression"),
    ])
    func syntaxErrorPositions(source: String, line: Int, column: Int, fragment: String) throws {
        let error = try #require(syntaxError(source), "expected a syntax error for \(source)")
        #expect(error.line == line, "\(error.message)")
        #expect(error.column == column, "\(error.message)")
        #expect(error.message.contains(fragment), "\(error.message)")
    }

    @Test func unknownFiltersAndTestsAreReportedWithPosition() throws {
        let filter = try #require(syntaxError("line\n{{ x | nosuchfilter }}"))
        #expect(filter.message.contains("No filter named 'nosuchfilter'"))
        #expect((filter.line, filter.column) == (2, 8))
        // Reported even when the branch never runs.
        let unused = try #require(syntaxError("{% if false %}{{ x | nope }}{% endif %}"))
        #expect(unused.message.contains("'nope'"))
        let test = try #require(syntaxError("{{ x is frobbed }}"))
        #expect(test.message.contains("No test named 'frobbed'"))
    }

    @Test func validateChecksFiltersAgainstAnEnvironment() throws {
        let template = try Template("{{ title | slugify }}")
        #expect(throws: TemplateError.self) { try template.validate(environment: .standard) }
        try template.validate(environment: .paperless)
    }

    @Test func errorDescriptions() {
        let syntax = TemplateError.syntax(message: "Boom", line: 3, column: 7)
        #expect(syntax.description == "Template syntax error at line 3, column 7: Boom")
        #expect(TemplateError.runtime("Bad").description == "Template error: Bad")
    }

    @Test func strictUndefinedRaisesOnUse() throws {
        var strict = TemplateEnvironment.standard
        strict.strictUndefined = true
        let message = try #require(runtimeError("line\n  {{ missing }}", environment: strict))
        #expect(message.contains("'missing' is undefined"))
        #expect(message.contains("line 2, column 6"))
        #expect(runtimeError("{{ d.missing }}", ["d": [:]], environment: strict)?.contains("'d.missing' is undefined") == true)
        #expect(runtimeError("{{ d['k'] }}", ["d": [:]], environment: strict)?.contains("'d['k']' is undefined") == true)
        #expect(runtimeError("{% if missing %}{% endif %}", environment: strict) != nil)
        #expect(runtimeError("{% for x in missing %}{% endfor %}", environment: strict) != nil)
        #expect(runtimeError("{{ missing | upper }}", environment: strict) != nil)
        #expect(runtimeError("{{ missing.attr }}", environment: strict) != nil)
        #expect(runtimeError("{{ 'a' ~ missing }}", environment: strict) != nil)
        #expect(runtimeError("{{ missing == 1 }}", environment: strict) != nil)
        // Tests and default handle undefined values without raising.
        #expect(try render("{{ missing is defined }}", environment: strict) == "False")
        #expect(try render("{{ missing | default('x') }}", environment: strict) == "x")
        #expect(try render("{{ d.k is defined }}", ["d": [:]], environment: strict) == "False")
        #expect(try render("{% if 'k' in d %}y{% else %}n{% endif %}", ["d": [:]], environment: strict) == "n")
        #expect(try render("{{ none }}", environment: strict) == "None")
    }

    @Test func undefinedInArithmeticAlwaysRaises() {
        // Jinja's default Undefined also refuses arithmetic and ordering.
        #expect(runtimeError("{{ missing + 1 }}")?.contains("'missing' is undefined") == true)
        #expect(runtimeError("{{ -missing }}") != nil)
        #expect(runtimeError("{{ missing < 1 }}") != nil)
        #expect(runtimeError("{{ missing.lower() }}") != nil)
    }

    @Test(arguments: [
        ("{{ 1 / 0 }}", "division by zero"),
        ("{{ 1 // 0 }}", "division by zero"),
        ("{{ 1 % 0 }}", "modulo by zero"),
        ("{{ 'a' + 1 }}", "unsupported operand type(s) for +: 'str' and 'int'"),
        ("{{ 1 - 'a' }}", "unsupported operand type(s) for -: 'int' and 'str'"),
        ("{{ 1 < 'a' }}", "'<' not supported between instances of 'int' and 'str'"),
        ("{{ 'a' in 1 }}", "argument of type 'int' is not iterable"),
        ("{{ 1 in 'abc' }}", "'in <string>' requires string as left operand, not int"),
        ("{% for x in 5 %}{% endfor %}", "'int' object is not iterable"),
        ("{% for a, b in [[1]] %}{% endfor %}", "not enough values to unpack (expected 2, got 1)"),
        ("{{ 5() }}", "'int' object is not callable"),
        ("{{ nothing() }}", "'nothing' is undefined"),
        ("{{ 'a'.frob() }}", "'str' object has no method 'frob'"),
        ("{{ range(1, 2, 0) }}", "must not be zero"),
        ("{{ range('a') }}", "'str' object cannot be interpreted as an integer"),
        ("{{ [1][1:2:0] }}", "slice step cannot be zero"),
        ("{{ 'x' | truncate(2) }}", "expected length >= 3"),
        ("{{ 'x' | replace }}", "missing required argument 'old'"),
        ("{{ 'x' | upper(1) }}", "takes at most"),
        ("{{ 'x' | lower(bad=1) }}", "unexpected keyword argument 'bad'"),
        ("{{ {1: 2} }}", "keys must be strings"),
        ("{% set ns = 1 %}{% set ns.a = 2 %}", "Cannot assign attribute 'a'"),
    ])
    func runtimeErrors(source: String, fragment: String) throws {
        let message = try #require(runtimeError(source), "expected a runtime error for \(source)")
        #expect(message.contains(fragment), "\(message)")
        #expect(message.contains("line 1, column"), "\(message)")
    }

    @Test func customFilterErrorsAreWrapped() throws {
        struct Failure: Error, CustomStringConvertible { var description: String { "boom" } }
        var environment = TemplateEnvironment.standard
        environment.registerFilter("explode") { _, _, _ in throw Failure() }
        environment.registerFilter("refuse") { _, _, _ in throw TemplateError.runtime("refused") }
        let wrapped = try #require(runtimeError("{{ 1 | explode }}", environment: environment))
        #expect(wrapped.contains("Filter 'explode' failed: boom"))
        #expect(wrapped.contains("line 1, column 8"))
        #expect(runtimeError("{{ 1 | refuse }}", environment: environment)?.hasPrefix("refused") == true)
    }
}
