import Foundation
import Testing
@testable import FolioTemplating

/// Examples and behaviour from Paperless-ngx: docs/advanced_usage.md ("Filename Templates")
/// and src/documents/tests/test_filters.py.
@Suite("Paperless-ngx compatibility")
struct PaperlessTests {
    private func renderPath(_ source: String, _ context: [String: TemplateValue]) throws -> String {
        try Template(source).renderFilePath(context)
    }

    @Test func paperlessEnvironmentMatchesPaperlessSettings() {
        let environment = TemplateEnvironment.paperless
        #expect(environment.trimBlocks)
        #expect(environment.lstripBlocks)
        #expect(!environment.keepTrailingNewline)
        #expect(environment.strictUndefined)
        for name in ["slugify", "datetime", "localize_date", "get_cf_value"] {
            #expect(environment.hasFilter(name))
            #expect(!TemplateEnvironment.standard.hasFilter(name))
        }
    }

    // MARK: Documentation examples

    private let asnTemplate = """
        somepath/
        {% if document.archive_serial_number >= 0 and document.archive_serial_number <= 200 %}
          asn-000-200/{{title}}
        {% elif document.archive_serial_number >= 201 and document.archive_serial_number <= 400 %}
          asn-201-400
          {% if document.archive_serial_number >= 201 and document.archive_serial_number < 300 %}
            /asn-2xx
          {% elif document.archive_serial_number >= 300 and document.archive_serial_number < 400 %}
            /asn-3xx
          {% endif %}
        {% endif %}
        /{{ title }}
        """

    @Test(arguments: [
        (205, "somepath/asn-201-400/asn-2xx/Title"),
        (355, "somepath/asn-201-400/asn-3xx/Title"),
        (100, "somepath/asn-000-200/Title/Title"),
        // No branch matches; Paperless-ngx's clean-up keeps the double slash too.
        (900, "somepath//Title"),
    ])
    func asnRangeExample(asn: Int, expected: String) throws {
        let context: [String: TemplateValue] = [
            "title": "Title",
            "document": ["archive_serial_number": .int(asn), "title": "Title"],
        ]
        #expect(try renderPath(asnTemplate, context) == expected)
    }

    @Test func asnRangeExampleRawOutputUsesTrimAndLstrip() throws {
        let context: [String: TemplateValue] = ["title": "Title", "document": ["archive_serial_number": 205]]
        let raw = try Template(asnTemplate).render(context, environment: .paperless)
        #expect(raw == "somepath/\n  asn-201-400\n    /asn-2xx\n/Title")
    }

    @Test(arguments: [
        ("application/pdf", "pdfs/Title"),
        ("image/png", "pngs/Title"),
        ("text/plain", "others/Title"),
    ])
    func mimeTypeExample(mimeType: String, expected: String) throws {
        let source = """
            {% if document.mime_type == "application/pdf" %}
              pdfs
            {% elif document.mime_type == "image/png" %}
              pngs
            {% else %}
              others
            {% endif %}
            /{{ title }}
            """
        let context: [String: TemplateValue] = ["title": "Title", "document": ["mime_type": .string(mimeType)]]
        #expect(try renderPath(source, context) == expected)
    }

    @Test func customFieldExample() throws {
        let source = """
            {% if "Invoice" in custom_fields %}
              invoices/{{ custom_fields.Invoice.value }}
            {% else %}
              not-invoices/{{ title }}
            {% endif %}
            """
        let invoice: [String: TemplateValue] = [
            "title": "Title",
            "custom_fields": ["Invoice": ["type": "integer", "value": 123]],
        ]
        #expect(try renderPath(source, invoice) == "invoices/123")
        let other: [String: TemplateValue] = ["title": "Title", "custom_fields": [:]]
        #expect(try renderPath(source, other) == "not-invoices/Title")
    }

    @Test func customFieldWithSpacesExample() throws {
        let source = "\"invoices/{{ custom_fields|get_cf_value('Invoice Number') }}\""
        let context: [String: TemplateValue] = [
            "custom_fields": ["Invoice Number": ["type": "string", "value": "123"]],
        ]
        #expect(try renderPath(source, context) == "\"invoices/123\"")
    }

    @Test func datetimeFilterExample() throws {
        let source = """
            invoices/
            {{ custom_fields|get_cf_value("Date Field","2024-01-01")|datetime('%Y') }}/
            {{ custom_fields|get_cf_value("Date Field","2024-01-01")|datetime('%m') }}/
            {{ custom_fields|get_cf_value("Date Field","2024-01-01")|datetime('%d') }}/
            Invoice_{{ custom_fields|get_cf_value("Select Field") }}_{{ custom_fields|get_cf_value("Date Field","2024-01-01")|replace("-", "") }}.pdf
            """
        let context: [String: TemplateValue] = [
            "custom_fields": [
                "Date Field": ["type": "date", "value": day(2022, 1, 1)],
                "Select Field": ["type": "select", "value": "OptionTwo"],
            ],
        ]
        #expect(try renderPath(source, context) == "invoices/2022/01/01/Invoice_OptionTwo_20220101.pdf")
        // Without the field, the string default is parsed.
        let defaults: [String: TemplateValue] = [
            "custom_fields": ["Select Field": ["type": "select", "value": "OptionOne"]],
        ]
        #expect(try renderPath(source, defaults) == "invoices/2024/01/01/Invoice_OptionOne_20240101.pdf")
    }

    @Test func slugifyExample() throws {
        #expect(try render("{{ title | slugify }}", ["title": "Hello World!"], environment: .paperless) == "hello-world")
    }

    @Test func storagePathExamples() throws {
        let context: [String: TemplateValue] = [
            "created_year": "2022", "created_month": "01", "created_day": "01",
            "correspondent": "Healthcare 123", "title": "Statement January",
        ]
        #expect(try renderPath("{{ created_year }}/{{ correspondent }}/{{ title }}", context)
            == "2022/Healthcare 123/Statement January")
        let insurances = "Insurances/{{ correspondent }}/{{ created_year }}-{{ created_month }}-{{ created_day }} {{ title }}"
        #expect(try renderPath(insurances, context) == "Insurances/Healthcare 123/2022-01-01 Statement January")
    }

    // MARK: get_cf_value

    @Test func getCustomFieldValue() throws {
        let fields: TemplateValue = [
            "department": ["type": "string", "value": "Sales"],
            "empty": ["type": "string", "value": nil],
        ]
        let context: [String: TemplateValue] = ["custom_fields": fields]
        let environment = TemplateEnvironment.paperless
        #expect(try render("{{ custom_fields | get_cf_value('department') }}", context, environment: environment) == "Sales")
        #expect(try render("{{ custom_fields | get_cf_value('phone', 'Not provided') }}", context, environment: environment)
            == "Not provided")
        #expect(try render("{{ custom_fields | get_cf_value('phone') }}", context, environment: environment) == "None")
        #expect(try render("{{ custom_fields | get_cf_value('empty', 'x') }}", context, environment: environment) == "x")
        #expect(try render("{{ custom_fields | get_cf_value('empty') is none }}", context, environment: environment)
            == "True")
        #expect(try render("{{ custom_fields | get_cf_value(name='department') }}", context, environment: environment)
            == "Sales")
    }

    // MARK: datetime

    @Test(arguments: [
        ("2026-09-21", "2026-09-21 00:00"),
        ("2026-09-21T13:45:00+00:00", "2026-09-21 13:45"),
        ("2026-09-21T13:45:00+02:00", "2026-09-21 13:45"),
        ("2026-09-21 13:45", "2026-09-21 13:45"),
        ("2026-09-21T13:45:59.123456Z", "2026-09-21 13:45"),
    ])
    func datetimeParsesIsoStrings(value: String, expected: String) throws {
        let source = "{{ value | datetime('%Y-%m-%d %H:%M') }}"
        #expect(try render(source, ["value": .string(value)], environment: .paperless) == expected)
    }

    @Test func datetimeRejectsUnparseableStrings() {
        let message = runtimeError("{{ 'not a date' | datetime('%Y') }}", environment: .paperless)
        #expect(message?.contains("Invalid date or datetime string: 'not a date'") == true)
    }

    @Test func datetimeDocExamples() throws {
        let environment = TemplateEnvironment.paperless
        let context: [String: TemplateValue] = [
            "created": dateTime(2024, 1, 15, 14, 30),
            "custom_fields": ["Date Field": ["type": "date", "value": day(2024, 1, 15)]],
        ]
        #expect(try render("{{ created | datetime('%B %d, %Y at %I:%M %p') }}", context, environment: environment)
            == "January 15, 2024 at 02:30 PM")
        #expect(try render("{{ custom_fields | get_cf_value('Date Field') | datetime('%A, %B %d, %Y') }}",
                           context, environment: environment) == "Monday, January 15, 2024")
    }

    @Test func datetimePythonSpecificDirectives() throws {
        let environment = TemplateEnvironment.paperless
        let context: [String: TemplateValue] = [
            "aware": dateTime(2024, 1, 15, 14, 30, 5, nanosecond: 123_456_000, timeZone: plusTwo),
            "plain": day(2024, 1, 15),
        ]
        #expect(try render("{{ aware | datetime('%f|%z|%:z|%%|%j|%a %b %-d') }}", context, environment: environment)
            == "123456|+0200|+02:00|%|015|Mon Jan 15")
        #expect(try render("{{ aware | datetime('%Z') }}", context, environment: environment) == "UTC+02:00")
        #expect(try render("{{ plain | datetime('%H:%M|%z|%Z|%f') }}", context, environment: environment)
            == "00:00|||000000")
        #expect(try render("{{ '2024-01-15' | datetime('%z') }}", environment: environment) == "")
        #expect(try render("{{ '2024-01-15T10:00:00Z' | datetime('%z %Z') }}", environment: environment) == "+0000 UTC")
    }

    @Test func datetimeUsesTheValuesOwnTimeZone() throws {
        var environment = TemplateEnvironment.paperless
        environment.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let context: [String: TemplateValue] = ["d": dateTime(2024, 1, 15, 23, 30)]
        #expect(try render("{{ d | datetime('%d %H:%M') }}", context, environment: environment) == "15 23:30")
    }

    // MARK: localize_date

    @Test(arguments: [
        ("short", "en_US", "1/15/24"),
        ("medium", "en_US", "Jan 15, 2024"),
        ("long", "en_US", "January 15, 2024"),
        ("full", "en_US", "Monday, January 15, 2024"),
        ("medium", "fr_FR", "15 janv. 2024"),
        ("medium", "de_DE", "15.01.2024"),
        ("dd/MM/yyyy", "en_GB", "15/01/2024"),
    ])
    func localizeDateDocExamples(format: String, locale: String, expected: String) throws {
        let context: [String: TemplateValue] = ["document": ["created": day(2024, 1, 15)]]
        let source = "{{ document.created | localize_date('\(format)', '\(locale)') }}"
        #expect(try render(source, context, environment: .paperless) == expected)
    }

    @Test(arguments: [
        ("EEEE, MMM d, yyyy", "en_US", "Thursday, Oct 26, 2023"),
        ("dd.MM.yyyy", "de_DE", "26.10.2023"),
        ("EEEE", "de_DE", "Donnerstag"),
        ("MMMM", "de_DE", "Oktober"),
        ("EEEE", "fr_FR", "jeudi"),
        ("MMMM", "fr_FR", "octobre"),
    ])
    func localizeDateWithDatesAndStrings(format: String, locale: String, expected: String) throws {
        let source = "{{ value | localize_date('\(format)', '\(locale)') }}"
        let values: [TemplateValue] = [day(2023, 10, 26), "2023-10-26", "2023-10-26T14:30:05+00:00"]
        for value in values {
            #expect(try render(source, ["value": value], environment: .paperless) == expected, "\(value)")
        }
    }

    @Test(arguments: [
        ("dd.MM.yyyy", "fr_FR", "26.10.2023"),
        ("EEEE", "es_ES", "jueves"),
        ("MMMM", "es_ES", "octubre"),
        ("EEEE", "it_IT", "giovedì"),
        ("MMMM", "it_IT", "ottobre"),
        // Babel prints "UTC" for the zone; Foundation's DateFormatter prints "GMT".
        ("yyyy.MM.dd G 'at' HH:mm:ss zzz", "en_US", "2023.10.26 AD at 14:30:05 GMT"),
    ])
    func localizeDateWithDateTimes(format: String, locale: String, expected: String) throws {
        let context: [String: TemplateValue] = ["value": dateTime(2023, 10, 26, 14, 30, 5)]
        let source = "{{ value | localize_date(\"\(format)\", '\(locale)') }}"
        #expect(try render(source, context, environment: .paperless) == expected)
    }

    @Test func localizeDatePresetsOnDateTimesIncludeTheTime() throws {
        // Babel's format_datetime adds the time for presets; DateFormatter's wording differs slightly.
        let context: [String: TemplateValue] = ["value": dateTime(2024, 1, 15, 14, 30)]
        #expect(try render("{{ value | localize_date('short', 'en_US') }}", context, environment: .paperless)
            == "1/15/24, 2:30\u{202F}PM")
        #expect(try render("{{ value | localize_date('medium', 'de_DE') }}", context, environment: .paperless)
            == "15.01.2024, 14:30:00")
    }

    @Test func localizeDateErrors() {
        let environment = TemplateEnvironment.paperless
        #expect(runtimeError("{{ d | localize_date('medium', 'invalid_locale_code') }}", ["d": day(2023, 10, 26)],
                             environment: environment)?.contains("Invalid locale identifier: invalid_locale_code") == true)
        for value: TemplateValue in [1_698_330_605, nil, [], [:]] {
            #expect(runtimeError("{{ d | localize_date('medium', 'en_US') }}", ["d": value], environment: environment)?
                .contains("Unsupported type") == true, "\(value)")
        }
    }

    // MARK: slugify

    @Test(arguments: [
        ("Hello World!", "hello-world"),
        ("  Leading and trailing  ", "leading-and-trailing"),
        ("Crème Brûlée", "creme-brulee"),
        ("a -- b __ c", "a-b-__-c"),
        ("_-_edge_-_", "edge"),
        ("Ünïcödé ﬁ", "unicode-fi"),
        ("日本語", ""),
        ("Tabs\tand\nnewlines", "tabs-and-newlines"),
        ("Invoice #123: (copy)", "invoice-123-copy"),
    ])
    func slugifyMatchesDjango(input: String, expected: String) throws {
        #expect(try render("{{ v | slugify }}", ["v": .string(input)], environment: .paperless) == expected)
    }

    @Test func slugifyAllowUnicode() throws {
        #expect(try render("{{ '日本 語!' | slugify(allow_unicode=true) }}", environment: .paperless) == "日本-語")
        #expect(try render("{{ 42 | slugify }}", environment: .paperless) == "42")
    }

    // MARK: MatchingModelContext

    @Test func relatedObjectRendersAsItsName() throws {
        let correspondent = TemplateValue.object(TemplateObject(
            typeName: "MatchingModelContext", text: "My bank", attributes: ["id": 7, "name": "My bank", "path": .none]))
        let context: [String: TemplateValue] = ["document": ["correspondent": correspondent, "storage_path": .none]]
        func check(_ source: String) throws -> String { try render(source, context, environment: .paperless) }
        #expect(try check("{{ document.correspondent }}") == "My bank")
        #expect(try check("{{ document.correspondent.name }}|{{ document.correspondent.id }}|{{ document.correspondent['id'] }}")
            == "My bank|7|7")
        #expect(try check("{{ document.correspondent | lower }}|{{ document.correspondent | slugify }}") == "my bank|my-bank")
        #expect(try check("{{ document.correspondent ~ '/x' }}|{{ document.correspondent | string }}") == "My bank/x|My bank")
        #expect(try check("{% if document.correspondent %}yes{% endif %}|{% if document.storage_path %}yes{% else %}no{% endif %}")
            == "yes|no")
        #expect(try check("{{ document.correspondent.missing is defined }}|{{ document.correspondent.path }}") == "False|None")
        #expect(try check("{{ document.correspondent is mapping }}|{{ document.correspondent is string }}") == "False|False")
        #expect(try check("{{ document.correspondent == 'My bank' }}") == "False")
    }

    // MARK: PlaceholderString

    @Test func placeholderBehavesLikePaperlessPlaceholderString() throws {
        let context: [String: TemplateValue] = ["correspondent": .placeholder("-none-"), "title": "T"]
        let environment = TemplateEnvironment.paperless
        func check(_ source: String) throws -> String { try render(source, context, environment: environment) }
        #expect(try check("{{ correspondent }}") == "-none-")
        #expect(try check("{% if correspondent %}yes{% else %}no{% endif %}") == "no")
        #expect(try check("{{ correspondent == 'none' }} {{ correspondent == '-none-' }} {{ 'none' == correspondent }}")
            == "True True True")
        #expect(try check("{{ correspondent != 'none' }} {{ correspondent == 'other' }}") == "False False")
        #expect(try check("{{ correspondent | upper }}|{{ correspondent | length }}|{{ correspondent is string }}")
            == "-NONE-|6|True")
        #expect(try check("{{ correspondent.replace('-', '') }}|{{ correspondent[1:5] }}") == "none|none")
        #expect(try check("{{ correspondent | default('Unknown', true) }}") == "Unknown")
        #expect(try check("{{ correspondent | default('Unknown') }}") == "-none-")
        #expect(try check("{{ [correspondent] }}") == "['-none-']")
        #expect(try check("{{ correspondent ~ '/' ~ title }}|{{ correspondent + '/' + title }}") == "-none-/T|-none-/T")
        #expect(try check("{{ 'none' in correspondent }}") == "True")
        // Falsy in every boolean context.
        #expect(try check("{{ correspondent and 'x' }}|{{ correspondent or 'fallback' }}|{{ not correspondent }}")
            == "-none-|fallback|True")
        #expect(try check("{{ 'a' if correspondent else 'b' }}") == "b")
        // String filters work on the text.
        #expect(try check("{{ correspondent | lower }}|{{ correspondent | replace('-', '_') }}|{{ correspondent | slugify }}")
            == "-none-|_none_|none")
        #expect(try check("{{ correspondent | title }}|{{ correspondent | trim('-') }}") == "-None-|none")
        // A different placeholder text does not alias "none".
        #expect(try render("{{ p == 'none' }}", ["p": .placeholder("n/a")]) == "False")
        #expect(TemplateValue.placeholder("x") != TemplateValue.string("x"))
    }

    // MARK: Undefined handling

    @Test func undefinedPlaceholdersFailInPaperlessMode() throws {
        #expect(runtimeError("{{ nope }}", environment: .paperless)?.contains("'nope' is undefined") == true)
        #expect(throws: TemplateError.self) { try Template("{{ nope }}").renderFilePath([:]) }
    }

    // MARK: Helpers

    @Test func renderFilePathCleansLikeFilePathTemplate() throws {
        #expect(try renderPath("  /a / b \n/ c/  ", [:]) == "a/b/c")
        #expect(try renderPath("dir/ my  file ", [:]) == "dir/my  file")
        // NFC normalisation.
        #expect(try renderPath("{{ t }}", ["t": "e\u{301}"]) == "\u{e9}")
        #expect(try renderPath("{{ t }}", ["t": "e\u{301}"]).unicodeScalars.count == 1)
    }

    @Test(arguments: [
        ("{title}", "{{ title }}"),
        ("{created_year}/{correspondent}/{title}", "{{ created_year }}/{{ correspondent }}/{{ title }}"),
        ("{{ title }} {title}", "{{ title }} {{ title }}"),
        ("{}", "{{  }}"),
        ("{not valid}", "{not valid}"),
    ])
    func convertLegacyFormat(old: String, expected: String) {
        #expect(Template.convertLegacyFormat(old) == expected)
    }

    @Test func undeclaredVariables() throws {
        let template = try Template("""
            {% set prefix = 'x' %}{{ prefix }}{{ title | upper }}{% for t in tags %}{{ t }}{{ loop.index }}{% endfor %}
            {{ range(3) | join }}{{ document.title }}{% if correspondent is defined %}{{ correspondent }}{% endif %}
            """)
        #expect(template.undeclaredVariables == ["title", "tags", "document", "correspondent"])
    }
}
