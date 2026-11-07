import Foundation
import Testing
@testable import FolioTemplating

@Suite("Statements")
struct StatementTests {
    @Test(arguments: [
        (5, "big"),
        (3, "medium"),
        (1, "small"),
    ])
    func ifElifElse(value: Int, expected: String) throws {
        let source = "{% if x > 4 %}big{% elif x > 2 %}medium{% else %}small{% endif %}"
        #expect(try render(source, ["x": .int(value)]) == expected)
    }

    @Test func ifWithoutElseRendersNothing() throws {
        #expect(try render("[{% if false %}x{% endif %}]") == "[]")
        #expect(try render("[{% if false %}x{% elif false %}y{% endif %}]") == "[]")
    }

    @Test func nestedIf() throws {
        let source = "{% if a %}{% if b %}ab{% else %}a{% endif %}{% else %}none{% endif %}"
        #expect(try render(source, ["a": true, "b": true]) == "ab")
        #expect(try render(source, ["a": true, "b": false]) == "a")
        #expect(try render(source, ["a": false]) == "none")
    }

    @Test func forLoopOverList() throws {
        #expect(try render("{% for x in items %}{{ x }},{% endfor %}", ["items": ["a", "b"]]) == "a,b,")
    }

    @Test func forLoopOverStringAndDict() throws {
        #expect(try render("{% for c in 'abc' %}{{ c }}.{% endfor %}") == "a.b.c.")
        // Dict iteration yields keys in sorted order.
        #expect(try render("{% for k in d %}{{ k }}{% endfor %}", ["d": ["b": 1, "a": 2]]) == "ab")
    }

    @Test func loopVariables() throws {
        let source = "{% for x in 'abc' %}"
            + "{{ loop.index }}{{ loop.index0 }}{{ loop.revindex }}{{ loop.revindex0 }}"
            + "{{ loop.first }}{{ loop.last }}{{ loop.length }};{% endfor %}"
        #expect(try render(source) == "1032TrueFalse3;2121FalseFalse3;3210FalseTrue3;")
    }

    @Test func loopPreviousAndNextItems() throws {
        let source = "{% for x in [1, 2, 3] %}{{ loop.previtem }}<{{ x }}>{{ loop.nextitem }} {% endfor %}"
        #expect(try render(source) == "<1>2 1<2>3 2<3> ")
    }

    @Test func forElseRunsWhenEmpty() throws {
        let source = "{% for x in items %}{{ x }}{% else %}empty{% endfor %}"
        #expect(try render(source, ["items": []]) == "empty")
        #expect(try render(source, ["items": [1]]) == "1")
        #expect(try render(source) == "empty")
    }

    @Test func forWithTupleUnpacking() throws {
        let source = "{% for k, v in pairs %}{{ k }}={{ v }} {% endfor %}"
        #expect(try render(source, ["pairs": [["a", 1], ["b", 2]]]) == "a=1 b=2 ")
        #expect(try render("{% for (a, b) in [[1, 2]] %}{{ a + b }}{% endfor %}") == "3")
    }

    @Test func nestedLoopsHaveTheirOwnLoopVariable() throws {
        let source = "{% for a in [1, 2] %}{% for b in 'xy' %}{{ loop.index }}{% endfor %}{{ loop.index }}|{% endfor %}"
        #expect(try render(source) == "121|122|")
    }

    @Test func forWithFilterCondition() throws {
        #expect(try render("{% for x in range(10) if x is even %}{{ x }}{% endfor %}") == "02468")
        #expect(try render("{% for x in range(10) if x > 6 %}{{ loop.length }}{% endfor %}") == "333")
    }

    @Test func breakAndContinue() throws {
        #expect(try render("{% for x in range(10) %}{% if x == 3 %}{% break %}{% endif %}{{ x }}{% endfor %}") == "012")
        #expect(try render("{% for x in range(6) %}{% if x is odd %}{% continue %}{% endif %}{{ x }}{% endfor %}")
            == "024")
        // break only leaves the innermost loop.
        let nested = "{% for a in 'ab' %}{% for b in 'xyz' %}{% if b == 'y' %}{% break %}{% endif %}"
            + "{{ a }}{{ b }}{% endfor %}{% endfor %}"
        #expect(try render(nested) == "axbx")
    }

    @Test func setAssignsVariables() throws {
        #expect(try render("{% set x = 5 %}{{ x * 2 }}") == "10")
        #expect(try render("{% set a, b = 1, 2 %}{{ a }}{{ b }}") == "12")
        #expect(try render("{% set name = name | upper %}{{ name }}", ["name": "bob"]) == "BOB")
    }

    @Test func setInsideLoopDoesNotLeak() throws {
        #expect(try render("{% set x = 1 %}{% for i in [1] %}{% set x = 2 %}{{ x }}{% endfor %}{{ x }}") == "21")
    }

    @Test func setInsideIfLeaks() throws {
        #expect(try render("{% if true %}{% set y = 3 %}{% endif %}{{ y }}") == "3")
    }

    @Test func namespaceCarriesStateOutOfLoops() throws {
        let source = "{% set ns = namespace(total=0) %}{% for i in range(4) %}"
            + "{% set ns.total = ns.total + i %}{% endfor %}{{ ns.total }}"
        #expect(try render(source) == "6")
    }

    @Test func blockSetCapturesOutput() throws {
        #expect(try render("{% set x %}a{{ 1 + 1 }}b{% endset %}[{{ x }}]") == "[a2b]")
    }

    @Test func rawBlocksAreNotInterpreted() throws {
        #expect(try render("{% raw %}{{ not rendered }}{% if %}{% endraw %}") == "{{ not rendered }}{% if %}")
        #expect(try render("a{%- raw -%}  {{ x }}  {%- endraw -%} b") == "a{{ x }}b")
    }

    @Test func commentsAreRemoved() throws {
        #expect(try render("a{# comment #}b") == "ab")
        #expect(try render("a{# multi\nline {{ x }} {% if %} #}b") == "ab")
    }

    @Test func tagsMayContainDelimitersInStrings() throws {
        #expect(try render("{{ '}}' }}") == "}}")
        #expect(try render("{% if '%}' %}yes{% endif %}") == "yes")
        #expect(try render("{{ {'a': 1}['a'] }}") == "1")
        #expect(try render("{{ {'a': {'b': 2}} }}") == "{'a': {'b': 2}}")
    }

    @Test func multiLineTags() throws {
        #expect(try render("{{\n  1 +\n  2\n}}") == "3")
        #expect(try render("{% if\n true\n %}y{% endif %}") == "y")
    }
}
