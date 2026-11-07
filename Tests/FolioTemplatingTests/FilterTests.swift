import Foundation
import Testing
@testable import FolioTemplating

@Suite("Built-in filters")
struct FilterTests {
    @Test(arguments: [
        ("{{ 'HeLLo' | lower }}", "hello"),
        ("{{ 'HeLLo' | upper }}", "HELLO"),
        ("{{ 'straße' | upper }}", "STRASSE"),
        ("{{ 'hello wORLD-foo (bar)  baz' | title }}", "Hello World-Foo (Bar)  Baz"),
        ("{{ 'hello WORLD' | capitalize }}", "Hello world"),
        ("{{ '  x y  ' | trim }}", "x y"),
        ("{{ '--x--' | trim('-') }}", "x"),
        ("{{ 'a-b-c' | replace('-', '_') }}", "a_b_c"),
        ("{{ 'a-b-c' | replace('-', '_', 1) }}", "a_b-c"),
        ("{{ 'ab' | replace('', '-') }}", "-a-b-"),
        ("{{ 42 | replace('4', 'x') }}", "x2"),
        ("{{ 'abc' | string }}", "abc"),
        ("{{ [1, 'a'] | string }}", "[1, 'a']"),
        ("{{ 'abc' | reverse }}", "cba"),
        ("{{ [1, 2, 3] | reverse }}", "[3, 2, 1]"),
        ("{{ 'abc' | list }}", "['a', 'b', 'c']"),
        ("{{ {'b': 1, 'a': 2} | list }}", "['a', 'b']"),
        ("{{ 'Hello, world! It\\'s 2024_ok' | wordcount }}", "5"),
        ("[{{ 'ab' | center(5) }}]", "[  ab ]"),
        ("[{{ 'abc' | center(6) }}]", "[ abc  ]"),
        ("[{{ 'abc' | center(2) }}]", "[abc]"),
        ("{{ 'a\\nb\\n\\nc' | indent }}", "a\n    b\n\n    c"),
        ("{{ 'a\\nb' | indent(2, true) }}", "  a\n  b"),
        ("{{ 'a\\n\\nb' | indent(blank=true) }}", "a\n    \n    b"),
        ("{{ 'a\\nb' | indent('> ') }}", "a\n> b"),
        ("{{ '<a href=\"x\">T&amp;C</a>' | safe }}", "<a href=\"x\">T&amp;C</a>"),
        ("{{ '<b>\"Tom\" & \\'Jerry\\'</b>' | escape }}", "&lt;b&gt;&#34;Tom&#34; &amp; &#39;Jerry&#39;&lt;/b&gt;"),
        ("{{ '<i>x</i>' | e }}", "&lt;i&gt;x&lt;/i&gt;"),
        ("{{ '<p>Hello <b>big</b>\\n  world</p><!-- note --> &amp; more' | striptags }}", "Hello big world & more"),
        ("{{ 'a b/c?d=é' | urlencode }}", "a%20b/c%3Fd%3D%C3%A9"),
        ("{{ {'q': 'a b&c', 'n': 1} | urlencode }}", "n=1&q=a+b%26c"),
    ])
    func stringFilters(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ 'foo bar baz qux' | truncate(9) }}", "foo..."),
        ("{{ 'foo bar baz qux' | truncate(9, true) }}", "foo ba..."),
        ("{{ 'foo bar baz qux' | truncate(9, end='!') }}", "foo bar!"),
        ("{{ 'foo bar baz' | truncate(9) }}", "foo bar baz"),
        ("{{ 'foo bar baz qux' | truncate(9, leeway=0) }}", "foo..."),
        ("{{ 'short' | truncate }}", "short"),
    ])
    func truncate(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ missing | default('fallback') }}", "fallback"),
        ("{{ missing | d('fallback') }}", "fallback"),
        ("{{ missing | default }}", ""),
        ("{{ '' | default('fallback') }}", ""),
        ("{{ '' | default('fallback', true) }}", "fallback"),
        ("{{ none | default('fallback') }}", "None"),
        ("{{ none | default('fallback', boolean=true) }}", "fallback"),
        ("{{ 'value' | default('fallback') }}", "value"),
    ])
    func defaultFilter(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ 'abc' | length }}", "3"),
        ("{{ 'é' | length }}", "1"),
        ("{{ [1, 2] | length }}", "2"),
        ("{{ {'a': 1} | count }}", "1"),
        ("{{ missing | length }}", "0"),
        ("{{ [1, 2, 3] | join }}", "123"),
        ("{{ [1, 2, 3] | join(', ') }}", "1, 2, 3"),
        ("{{ [{'n': 'a'}, {'n': 'b'}] | join('/', attribute='n') }}", "a/b"),
        ("{{ [1, 2, 3] | first }} {{ [1, 2, 3] | last }}", "1 3"),
        ("{{ 'abc' | first }}{{ 'abc' | last }}", "ac"),
        ("[{{ [] | first }}]", "[]"),
        ("{{ [3, 1, 2] | sort }}", "[1, 2, 3]"),
        ("{{ [3, 1, 2] | sort(reverse=true) }}", "[3, 2, 1]"),
        ("{{ ['b', 'A', 'c'] | sort }}", "['A', 'b', 'c']"),
        ("{{ ['b', 'A', 'c'] | sort(case_sensitive=true) }}", "['A', 'b', 'c']"),
        ("{{ ['b', 'a', 'C'] | sort(case_sensitive=true) }}", "['C', 'a', 'b']"),
        ("{{ [{'n': 2}, {'n': 1}] | sort(attribute='n') | map(attribute='n') | list }}", "[1, 2]"),
        ("{{ [1, 2, 1, 3, 2] | unique }}", "[1, 2, 3]"),
        ("{{ ['a', 'A', 'b'] | unique }}", "['a', 'b']"),
        ("{{ [1, 1.0, true] | unique }}", "[1]"),
        ("{{ [3, 1, 2] | min }} {{ [3, 1, 2] | max }}", "1 3"),
        ("{{ ['b', 'A', 'c'] | min }} {{ ['b', 'A', 'C'] | max }}", "A C"),
        ("[{{ [] | max }}]", "[]"),
        ("{{ [1, 2, 3] | sum }}", "6"),
        ("{{ [1, 2.5] | sum }}", "3.5"),
        ("{{ [1, 2] | sum(start=10) }}", "13"),
        ("{{ [{'v': 2}, {'v': 3}] | sum(attribute='v') }}", "5"),
        ("{{ {'b': 1, 'a': 2} | items | list }}", "[['a', 2], ['b', 1]]"),
        ("{{ {'b': 1, 'A': 2} | dictsort }}", "[['A', 2], ['b', 1]]"),
        ("{{ {'b': 1, 'a': 2} | dictsort(by='value') }}", "[['b', 1], ['a', 2]]"),
        ("{{ ['a', 'b'] | map('upper') | join }}", "AB"),
        ("{{ [{'n': 'x'}, {}] | map(attribute='n', default='?') | join }}", "x?"),
        ("{{ range(6) | select('odd') | list }}", "[1, 3, 5]"),
        ("{{ range(6) | reject('odd') | list }}", "[0, 2, 4]"),
        ("{{ [0, 1, '', 'a'] | select | list }}", "[1, 'a']"),
        ("{{ range(10) | select('divisibleby', 3) | list }}", "[0, 3, 6, 9]"),
        ("{{ [{'a': 1}, {'a': 0}] | selectattr('a') | list }}", "[{'a': 1}]"),
        ("{{ [{'a': 1}, {'a': 2}] | selectattr('a', 'equalto', 2) | list }}", "[{'a': 2}]"),
        ("{{ [{'a': 1}, {'a': 0}] | rejectattr('a') | list }}", "[{'a': 0}]"),
        ("{{ {'n': 'x'} | attr('n') }}", "x"),
    ])
    func sequenceFilters(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ '42' | int }}", "42"),
        ("{{ '  42 ' | int }}", "42"),
        ("{{ '3.7' | int }}", "3"),
        ("{{ 3.9 | int }}", "3"),
        ("{{ -3.9 | int }}", "-3"),
        ("{{ true | int }}", "1"),
        ("{{ 'abc' | int }}", "0"),
        ("{{ 'abc' | int(7) }}", "7"),
        ("{{ none | int(default=-1) }}", "-1"),
        ("{{ 'ff' | int(base=16) }}", "255"),
        ("{{ '0x1A' | int(0, 16) }}", "26"),
        ("{{ '1.5' | float }}", "1.5"),
        ("{{ 2 | float }}", "2.0"),
        ("{{ 'x' | float }}", "0.0"),
        ("{{ 'x' | float(1.5) }}", "1.5"),
        ("{{ -3 | abs }}", "3"),
        ("{{ -2.5 | abs }}", "2.5"),
        ("{{ 3.14159 | round(2) }}", "3.14"),
        ("{{ 2.675 | round(2) }}", "2.67"),
        ("{{ 2.5 | round }}", "2.0"),
        ("{{ 3.5 | round }}", "4.0"),
        ("{{ 3 | round }}", "3"),
        ("{{ 1234.5 | round(-2) }}", "1200.0"),
        ("{{ 2.1 | round(method='ceil') }}", "3.0"),
        ("{{ 2.9 | round(method='floor') }}", "2.0"),
        ("{{ 2.25 | round(1, 'floor') }}", "2.2"),
    ])
    func numericFilters(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test(arguments: [
        ("{{ '%s-%d' | format('a', 7) }}", "a-7"),
        ("{{ '%5.1f|%-5d|%05d|%+d' | format(3.14159, 42, 42, 5) }}", "  3.1|42   |00042|+5"),
        ("{{ '%x|%#x|%#o|%X' | format(255, 255, 8, 255) }}", "ff|0xff|0o10|FF"),
        ("{{ '%e|%g' | format(12345.678, 0.0001234) }}", "1.234568e+04|0.0001234"),
        ("{{ '%s|%r|%c|%.2s' | format([1, 'a'], 'q', 65, 'abc') }}", "[1, 'a']|'q'|A|ab"),
        ("{{ '%(a)s-%(b)03d' | format(a='x', b=7) }}", "x-007"),
        ("{{ '%.3d|%d' | format(5, 3.9) }}", "005|3"),
        ("{{ '100%%' | format() }}", "100%"),
        ("{{ '%5s|%-5s|' | format('ab', 'cd') }}", "   ab|cd   |"),
    ])
    func formatFilter(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func formatFilterErrors() {
        #expect(runtimeError("{{ '%s %s' | format('a') }}")?.contains("not enough arguments") == true)
        #expect(runtimeError("{{ '%s' | format('a', 'b') }}")?.contains("not all arguments converted") == true)
        #expect(runtimeError("{{ '%d' | format('a') }}")?.contains("a real number is required") == true)
    }

    @Test func chainedFilters() throws {
        #expect(try render("{{ '  Hello World  ' | trim | lower | replace(' ', '-') }}") == "hello-world")
        #expect(try render("{{ names | map('lower') | sort | join(', ') }}", ["names": ["Bob", "alice"]])
            == "alice, bob")
    }

    @Test func customFilters() throws {
        var environment = TemplateEnvironment.standard
        environment.registerFilter("shout") { value, args, kwargs in
            let suffix = args.first?.description ?? "!"
            let times = if case .int(let n) = kwargs["times"] { n } else { 1 }
            return .string(value.description.uppercased() + String(repeating: suffix, count: times))
        }
        #expect(try render("{{ 'hi' | shout }}", environment: environment) == "HI!")
        #expect(try render("{{ 'hi' | shout('?', times=3) }}", environment: environment) == "HI???")
        // Custom filters can replace built-ins.
        environment.registerFilter("upper") { _, _, _ in "replaced" }
        #expect(try render("{{ 'hi' | upper }}", environment: environment) == "replaced")
    }

    @Test func filtersOnUndefinedInLenientMode() throws {
        #expect(try render("[{{ missing | upper }}]") == "[]")
        #expect(try render("{{ missing | list }}") == "[]")
        #expect(try render("{{ missing | int }}") == "0")
    }
}

@Suite("Tests (is)")
struct TestExpressionTests {
    @Test(arguments: [
        ("{{ x is defined }}", "True"),
        ("{{ missing is defined }}", "False"),
        ("{{ missing is undefined }}", "True"),
        ("{{ missing is not defined }}", "True"),
        ("{{ n is none }}", "True"),
        ("{{ x is not none }}", "True"),
        ("{{ 1 is number }}", "True"),
        ("{{ 1.5 is number }}", "True"),
        ("{{ '1' is number }}", "False"),
        ("{{ true is boolean }}", "True"),
        ("{{ 1 is integer }}", "True"),
        ("{{ true is integer }}", "False"),
        ("{{ 1.0 is float }}", "True"),
        ("{{ 's' is string }}", "True"),
        ("{{ 1 is string }}", "False"),
        ("{{ {} is mapping }}", "True"),
        ("{{ [] is sequence }}", "True"),
        ("{{ 'abc' is iterable }}", "True"),
        ("{{ 1 is iterable }}", "False"),
        ("{{ 4 is even }}", "True"),
        ("{{ 4 is odd }}", "False"),
        ("{{ 3 is odd }}", "True"),
        ("{{ 9 is divisibleby 3 }}", "True"),
        ("{{ 9 is divisibleby(4) }}", "False"),
        ("{{ 'abc' is lower }}", "True"),
        ("{{ 'ABC' is upper }}", "True"),
        ("{{ true is true }}", "True"),
        ("{{ 1 is true }}", "False"),
        ("{{ false is false }}", "True"),
        ("{{ 2 is eq 2 }}", "True"),
        ("{{ 2 is equalto 3 }}", "False"),
        ("{{ 2 is ne 3 }}", "True"),
        ("{{ 2 is lt 3 }}", "True"),
        ("{{ 2 is gt 3 }}", "False"),
        ("{{ 2 is ge 2 }}", "True"),
        ("{{ 2 is le 1 }}", "False"),
        ("{{ 2 is in [1, 2] }}", "True"),
        ("{{ none is sameas none }}", "True"),
        ("{{ x is defined and x == 'v' }}", "True"),
        ("{{ x is string or false }}", "True"),
        ("{{ 'a' if x is defined else 'b' }}", "a"),
    ])
    func builtInTests(source: String, expected: String) throws {
        #expect(try render(source, ["x": "v", "n": nil]) == expected)
    }
}
