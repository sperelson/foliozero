import Foundation
import Testing
@testable import FolioTemplating

@Suite("Values and rendering")
struct ValueRenderingTests {
    @Test func plainTextPassesThroughUnchanged() throws {
        #expect(try render("Hello, world! } { %} #} }}") == "Hello, world! } { %} #} }}")
        #expect(try render("") == "")
        #expect(try render("line 1\nline 2") == "line 1\nline 2")
    }

    @Test func variableSubstitution() throws {
        #expect(try render("Hello {{ name }}!", ["name": "World"]) == "Hello World!")
        #expect(try render("{{name}}", ["name": "tight"]) == "tight")
    }

    @Test func literalExpressionsBuildValues() throws {
        let literal: TemplateValue = [
            "s": "text", "i": 3, "d": 1.5, "b": true, "n": nil, "list": [1, "a"],
        ]
        #expect(literal == .dict([
            "s": .string("text"), "i": .int(3), "d": .double(1.5), "b": .bool(true), "n": .none,
            "list": .array([.int(1), .string("a")]),
        ]))
    }

    @Test(arguments: [
        ("{{ 1 }}", "1"),
        ("{{ -17 }}", "-17"),
        ("{{ 1_000 }}", "1000"),
        ("{{ 12.5 }}", "12.5"),
        ("{{ 1.0 }}", "1.0"),
        ("{{ 1e3 }}", "1000.0"),
        ("{{ 2.5e-3 }}", "0.0025"),
        ("{{ 0x1F }}", "31"),
        ("{{ true }}", "True"),
        ("{{ True }}", "True"),
        ("{{ false }}", "False"),
        ("{{ False }}", "False"),
        ("{{ none }}", "None"),
        ("{{ None }}", "None"),
        ("{{ missing }}", ""),
        ("{{ 'single' }}", "single"),
        ("{{ \"double\" }}", "double"),
        ("{{ 'a' \"b\" 'c' }}", "abc"),
        ("{{ 'it\\'s' }}", "it's"),
        ("{{ \"tab\\there\" }}", "tab\there"),
        ("{{ 'new\\nline' }}", "new\nline"),
        ("{{ '\\u00e9\\x41' }}", "\u{e9}A"),
        ("{{ 'keep\\d' }}", "keep\\d"),
        ("{{ [1, 'a', none, true, 2.5] }}", "[1, 'a', None, True, 2.5]"),
        ("{{ [] }}", "[]"),
        ("{{ {'b': 2, 'a': 1} }}", "{'a': 1, 'b': 2}"),
        ("{{ {} }}", "{}"),
        ("{{ [\"it's\", 'say \"hi\"', 'both \\' \"'] }}", "[\"it's\", 'say \"hi\"', 'both \\' \"']"),
        ("{{ ['a\\nb', '\\\\'] }}", "['a\\nb', '\\\\']"),
        ("{{ [[1, 2], {'k': [3]}] }}", "[[1, 2], {'k': [3]}]"),
        ("{{ (1) }}", "1"),
        ("{{ (1, 2) }}", "[1, 2]"),
    ])
    func literalRendering(source: String, expected: String) throws {
        #expect(try render(source) == expected)
    }

    @Test func contextValuesRenderLikePythonStr() throws {
        let context: [String: TemplateValue] = [
            "i": .int(42),
            "d": .double(0.1 + 0.2),
            "whole": .double(3),
            "b": .bool(false),
            "n": .none,
            "u": .undefined,
            "list": .array(["x", .int(1), .double(2.0), .none]),
            "dict": .dict(["z": "last", "a": .array([])]),
        ]
        #expect(try render("{{ i }}|{{ d }}|{{ whole }}|{{ b }}|{{ n }}|{{ u }}", context)
            == "42|0.30000000000000004|3.0|False|None|")
        #expect(try render("{{ list }}", context) == "['x', 1, 2.0, None]")
        #expect(try render("{{ dict }}", context) == "{'a': [], 'z': 'last'}")
    }

    @Test(arguments: [
        (1e-05, "1e-05"),
        (0.0001, "0.0001"),
        (1e15, "1000000000000000.0"),
        (1e16, "1e+16"),
        (123456789012345678.0, "1.2345678901234568e+17"),
        (-0.0, "-0.0"),
        (Double.infinity, "inf"),
        (-Double.infinity, "-inf"),
        (Double.nan, "nan"),
        (5e-324, "5e-324"),
    ])
    func floatsRenderLikePythonRepr(value: Double, expected: String) throws {
        #expect(try render("{{ x }}", ["x": .double(value)]) == expected)
    }

    @Test func descriptionIsPythonStr() {
        #expect(TemplateValue.array(["a", 1]).description == "['a', 1]")
        #expect(TemplateValue.undefined.description == "")
        #expect(TemplateValue.bool(true).description == "True")
        #expect(TemplateValue.string("x").pythonRepr == "'x'")
    }

    @Test func truthinessFollowsPython() {
        let falsy: [TemplateValue] = ["", 0, 0.0, false, nil, .undefined, [], [:]]
        let truthy: [TemplateValue] = ["0", " ", 1, -1, 0.5, true, [0], ["k": nil], day(2024, 1, 1)]
        for value in falsy { #expect(!value.isTruthy, "\(value)") }
        for value in truthy { #expect(value.isTruthy, "\(value)") }
    }

    @Test func truthinessInTemplates() throws {
        let template = "{% if x %}T{% else %}F{% endif %}"
        let cases: [(TemplateValue, String)] = [
            ("", "F"), ("a", "T"), (0, "F"), (2, "T"), (0.0, "F"), (nil, "F"),
            ([], "F"), ([1], "T"), ([:], "F"), (["a": 1], "T"), (.undefined, "F"),
        ]
        for (value, expected) in cases {
            #expect(try render(template, ["x": value]) == expected, "\(value)")
        }
    }

    @Test func dateOnlyRendersAsIsoDate() throws {
        #expect(try render("{{ d }}", ["d": day(2024, 3, 14)]) == "2024-03-14")
        // The calendar day is read in the value's own time zone.
        #expect(try render("{{ d }}", ["d": day(2024, 3, 14, timeZone: plusTwo)]) == "2024-03-14")
    }

    @Test func dateTimeRendersLikePythonStrDatetime() throws {
        #expect(try render("{{ d }}", ["d": dateTime(2024, 3, 14, 10, 15, timeZone: plusTwo)])
            == "2024-03-14 10:15:00+02:00")
        #expect(try render("{{ d }}", ["d": dateTime(2024, 3, 14, 10, 15, 7)]) == "2024-03-14 10:15:07+00:00")
        #expect(try render("{{ d }}", ["d": dateTime(2024, 3, 14, 10, 15, nanosecond: 250_000_000)])
            == "2024-03-14 10:15:00.250000+00:00")
        let minusFiveThirty = TimeZone(secondsFromGMT: -(5 * 3600 + 30 * 60))!
        #expect(try render("{{ d }}", ["d": dateTime(2024, 3, 14, 1, 2, timeZone: minusFiveThirty)])
            == "2024-03-14 01:02:00-05:30")
    }

    @Test func dateAttributes() throws {
        let context: [String: TemplateValue] = ["d": dateTime(2024, 3, 14, 10, 15, 30, timeZone: plusTwo)]
        #expect(try render("{{ d.year }}-{{ d.month }}-{{ d.day }} {{ d.hour }}:{{ d.minute }}:{{ d.second }}", context)
            == "2024-3-14 10:15:30")
        #expect(try render("{{ d.year + 1 }}", context) == "2025")
        #expect(try render("{{ d['year'] }}", context) == "2024")
        #expect(try render("{{ d.nonexistent }}", context) == "")
    }

    @Test func dateMethods() throws {
        let context: [String: TemplateValue] = [
            "d": dateTime(2024, 3, 14, 10, 15, timeZone: plusTwo),
            "dd": day(2024, 3, 14),
        ]
        #expect(try render("{{ d.strftime('%Y/%m/%d %H:%M %z') }}", context) == "2024/03/14 10:15 +0200")
        #expect(try render("{{ d.isoformat() }}", context) == "2024-03-14T10:15:00+02:00")
        #expect(try render("{{ dd.isoformat() }}", context) == "2024-03-14")
        #expect(try render("{{ d.weekday() }} {{ d.isoweekday() }}", context) == "3 4")
        #expect(try render("{{ d.date() }}", context) == "2024-03-14")
    }

    @Test func dateComparisons() throws {
        let context: [String: TemplateValue] = [
            "early": dateTime(2024, 1, 1, 9, 0),
            "late": dateTime(2024, 1, 1, 10, 0),
            // The same instant as `late`, seen from UTC+2.
            "lateElsewhere": dateTime(2024, 1, 1, 12, 0, timeZone: plusTwo),
            "a": day(2024, 1, 1),
            "b": day(2024, 1, 2),
        ]
        #expect(try render("{{ early < late }} {{ late > early }} {{ early >= late }}", context) == "True True False")
        #expect(try render("{{ late == lateElsewhere }} {{ late != early }}", context) == "True True")
        #expect(try render("{{ a < b }} {{ a == a }} {{ [a, b] | max }}", context) == "True True 2024-01-02")
    }

    @Test func dateRepr() throws {
        #expect(try render("{{ [d] }}", ["d": day(2024, 3, 14)]) == "[datetime.date(2024, 3, 14)]")
        #expect(try render("{{ [d] }}", ["d": dateTime(2024, 3, 14, 10, 15)])
            == "[datetime.datetime(2024, 3, 14, 10, 15, tzinfo=datetime.timezone.utc)]")
    }
}
