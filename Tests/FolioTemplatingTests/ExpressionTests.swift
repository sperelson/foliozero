import Foundation
import Testing
@testable import FolioTemplating

@Suite("Expressions")
struct ExpressionTests {
    @Test(arguments: [
        ("{{ 1 + 2 }}", "3"),
        ("{{ 1 + 2.5 }}", "3.5"),
        ("{{ 5 - 7 }}", "-2"),
        ("{{ 2 * 3 + 1 }}", "7"),
        ("{{ 2 * (3 + 1) }}", "8"),
        ("{{ 10 / 4 }}", "2.5"),
        ("{{ 10 / 5 }}", "2.0"),
        ("{{ 7 // 2 }}", "3"),
        ("{{ -7 // 2 }}", "-4"),
        ("{{ 7.5 // 2 }}", "3.0"),
        ("{{ 7 % 3 }}", "1"),
        ("{{ -7 % 3 }}", "2"),
        ("{{ 7.5 % 2 }}", "1.5"),
        ("{{ -7.5 % 2 }}", "0.5"),
        ("{{ 2 ** 10 }}", "1024"),
        ("{{ 2 ** -1 }}", "0.5"),
        ("{{ 2.0 ** 2 }}", "4.0"),
        ("{{ -3 + 1 }}", "-2"),
        ("{{ -(2 + 3) }}", "-5"),
        ("{{ +4 }}", "4"),
        ("{{ true + 1 }}", "2"),
        ("{{ 'a' + 'b' }}", "ab"),
        ("{{ [1] + [2, 3] }}", "[1, 2, 3]"),
        ("{{ 'ab' * 3 }}", "ababab"),
        ("{{ 3 * 'ab' }}", "ababab"),
        ("{{ 'ab' * 0 }}", ""),
        ("{{ [0] * 3 }}", "[0, 0, 0]"),
        ("{{ 1 ~ 'a' ~ none ~ true }}", "1aNoneTrue"),
        ("{{ 'x' ~ missing ~ 'y' }}", "xy"),
        ("{{ 2 * 3 ~ 'x' }}", "6x"),
        // Jinja binds ** to the unary minus first and is left-associative.
        ("{{ -2 ** 2 }}", "4"),
        ("{{ 2 ** 3 ** 2 }}", "64"),
        ("{{ 1 + 2 * 3 ** 2 }}", "19"),
    ])
    func arithmetic(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ 1 == 1.0 }}", "True"),
        ("{{ true == 1 }}", "True"),
        ("{{ 'a' == 'a' }}", "True"),
        ("{{ 'a' == 1 }}", "False"),
        ("{{ none == none }}", "True"),
        ("{{ [1, 'a'] == [1, 'a'] }}", "True"),
        ("{{ {'a': 1} == {'a': 1.0} }}", "True"),
        ("{{ 1 != 2 }}", "True"),
        ("{{ 1 < 2.5 }}", "True"),
        ("{{ 'a' < 'b' }}", "True"),
        ("{{ 'B' < 'a' }}", "True"),
        ("{{ [1, 2] < [1, 3] }}", "True"),
        ("{{ [1, 2] < [1, 2, 0] }}", "True"),
        ("{{ 2 >= 2 }}", "True"),
        ("{{ 2 <= 1 }}", "False"),
        ("{{ 1 < 2 < 3 }}", "True"),
        ("{{ 3 > 2 > 2 }}", "False"),
        ("{{ 'a' in 'cat' }}", "True"),
        ("{{ 'dog' in 'cat' }}", "False"),
        ("{{ 2 in [1, 2] }}", "True"),
        ("{{ 2.0 in [1, 2] }}", "True"),
        ("{{ 'k' in {'k': 1} }}", "True"),
        ("{{ 'v' in {'k': 'v'} }}", "False"),
        ("{{ 3 not in [1, 2] }}", "True"),
        ("{{ not 'x' in 'abc' }}", "True"),
        ("{{ 'x' in missing }}", "False"),
    ])
    func comparisons(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ true and false }}", "False"),
        ("{{ true or false }}", "True"),
        ("{{ 0 or 'default' }}", "default"),
        ("{{ 'first' or 'second' }}", "first"),
        ("{{ 1 and 'x' }}", "x"),
        ("{{ '' and 'x' }}", ""),
        ("{{ not 0 }}", "True"),
        ("{{ not [] }}", "True"),
        ("{{ not not 'a' }}", "True"),
        ("{{ false or false and true }}", "False"),
        ("{{ true or false and false }}", "True"),
        ("{{ not true or true }}", "True"),
        ("{{ 'yes' if 1 > 0 else 'no' }}", "yes"),
        ("{{ 'yes' if [] else 'no' }}", "no"),
        ("{{ 'x' if false }}", ""),
        ("{{ 'a' if false else 'b' if true else 'c' }}", "b"),
        ("{{ (1 if true else 2) + 10 }}", "11"),
    ])
    func logicAndConditionals(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func shortCircuitSkipsTheRightOperand() throws {
        // The right operand would fail; it must not be evaluated.
        #expect(try render("{{ true or (1 / 0) }}") == "True")
        #expect(try render("{{ false and (1 / 0) }}") == "False")
        #expect(try render("{{ 'a' if true else 1 / 0 }}") == "a")
    }

    @Test(arguments: [
        ("{{ 'abc'[1] }}", "b"),
        ("{{ 'abc'[-1] }}", "c"),
        ("{{ [1, 2, 3, 4][1:3] }}", "[2, 3]"),
        ("{{ [1, 2, 3][:-1] }}", "[1, 2]"),
        ("{{ [1, 2, 3][1:] }}", "[2, 3]"),
        ("{{ [1, 2, 3, 4, 5][::2] }}", "[1, 3, 5]"),
        ("{{ 'hello'[::-1] }}", "olleh"),
        ("{{ 'hello'[1:4] }}", "ell"),
        ("{{ [1, 2, 3][5] }}", ""),
        ("{{ [1, 2, 3][-5:10] }}", "[1, 2, 3]"),
        ("{{ {'a': {'b': 1}}.a.b }}", "1"),
        ("{{ {'a': 1}['a'] }}", "1"),
        ("{{ {'a': 1}['zz'] }}", ""),
        ("{{ [10, 20].1 }}", "20"),
        ("{{ [[1, 2], [3, 4]][1][0] }}", "3"),
        ("{{ 'é'[0] }}", "é"),
    ])
    func subscriptsAndSlices(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func attributeLookupFallsBackToDictKeys() throws {
        let context: [String: TemplateValue] = [
            "doc": ["title": "Invoice", "owner": ["name": "alice"], "tags": ["a", "b"], "nothing": nil],
        ]
        #expect(try render("{{ doc.title }}/{{ doc.owner.name }}/{{ doc.tags[1] }}", context) == "Invoice/alice/b")
        #expect(try render("{{ doc['title'] }}", context) == "Invoice")
        #expect(try render("[{{ doc.missing }}]", context) == "[]")
        #expect(try render("[{{ doc.missing.deeper }}]", context) == "[]")
        #expect(try render("[{{ doc.nothing.name }}]", context) == "[]")
        #expect(try render("{{ doc.title.lower() }}", context) == "invoice")
    }

    @Test(arguments: [
        ("{{ 'Hello'.lower() }}", "hello"),
        ("{{ 'Hello'.upper() }}", "HELLO"),
        ("{{ '  x  '.strip() }}", "x"),
        ("{{ 'xxaxx'.strip('x') }}", "a"),
        ("{{ '  x  '.lstrip() }}|", "x  |"),
        ("{{ '  x  '.rstrip() }}|", "  x|"),
        ("{{ 'a-b-c'.replace('-', '/') }}", "a/b/c"),
        ("{{ 'a-b-c'.replace('-', '/', 1) }}", "a/b-c"),
        ("{{ 'abc'.startswith('ab') }}", "True"),
        ("{{ 'abc'.startswith(('x', 'a')) }}", "True"),
        ("{{ 'abc'.endswith('bc') }}", "True"),
        ("{{ 'abc'.endswith('b') }}", "False"),
        ("{{ 'a,b,,c'.split(',') }}", "['a', 'b', '', 'c']"),
        ("{{ ' a  b '.split() }}", "['a', 'b']"),
        ("{{ 'a b c'.split(none, 1) }}", "['a', 'b c']"),
        ("{{ 'a,b,c'.split(',', 1) }}", "['a', 'b,c']"),
        ("{{ \"they're bill's friends\".title() }}", "They'Re Bill'S Friends"),
        ("{{ 'hello wORLD'.capitalize() }}", "Hello world"),
        ("{{ '-'.join(['a', 'b']) }}", "a-b"),
        ("{{ '42'.zfill(5) }}", "00042"),
        ("{{ '42'.isdigit() }} {{ '4a'.isdigit() }}", "True False"),
        ("{{ 'banana'.count('a') }}", "3"),
        ("{{ 'banana'.find('n') }} {{ 'banana'.find('z') }}", "2 -1"),
    ])
    func stringMethods(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func dictMethods() throws {
        let context: [String: TemplateValue] = ["d": ["b": 2, "a": 1]]
        #expect(try render("{{ d.items() }}", context) == "[['a', 1], ['b', 2]]")
        #expect(try render("{{ d.keys() }}", context) == "['a', 'b']")
        #expect(try render("{{ d.values() }}", context) == "[1, 2]")
        #expect(try render("{{ d.get('a') }}|{{ d.get('z') }}|{{ d.get('z', 'def') }}", context) == "1|None|def")
        #expect(try render("{% for k, v in d.items() %}{{ k }}={{ v }};{% endfor %}", context) == "a=1;b=2;")
    }

    @Test(arguments: [
        ("{{ range(3) | list }}", "[0, 1, 2]"),
        ("{{ range(1, 10, 3) | list }}", "[1, 4, 7]"),
        ("{{ range(5, 0, -2) | list }}", "[5, 3, 1]"),
        ("{{ range(0) | list }}", "[]"),
        ("{{ range(3, 1) | list }}", "[]"),
    ])
    func rangeFunction(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func dictAndNamespaceFunctions() throws {
        #expect(try render("{{ dict(a=1, b='x') }}") == "{'a': 1, 'b': 'x'}")
        #expect(try render("{% set ns = namespace(count=2) %}{{ ns.count }}") == "2")
    }

    @Test func percentOperatorFormatsStrings() throws {
        #expect(try render("{{ '%s-%03d' % ('a', 7) }}") == "a-007")
        #expect(try render("{{ '%s!' % 'hi' }}") == "hi!")
        #expect(try render("{{ '%(x)s' % {'x': 1} }}") == "1")
    }

    @Test func filtersBindTighterThanOperators() throws {
        #expect(try render("{{ -1 | abs }}") == "1")
        #expect(try render("{{ 1 + -1 | abs }}") == "2")
        #expect(try render("{{ 'a' ~ 'b' | upper }}") == "aB")
        #expect(try render("{{ ('a' ~ 'b') | upper }}") == "AB")
    }

    @Test func contextVariablesShadowGlobals() throws {
        #expect(try render("{{ range }}", ["range": "mine"]) == "mine")
    }
}
