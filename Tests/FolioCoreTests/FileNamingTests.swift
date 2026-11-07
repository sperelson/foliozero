import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct FileNamingTests {
    let utc = TimeZone(identifier: "UTC")!

    func context(title: String = "Statement January", correspondent: String? = "My bank", tags: [String] = [], asn: Int? = nil) -> NamingContext {
        var document = Document.fixture(title, created: CalendarDate(year: 2019, month: 1, day: 31), asn: asn)
        document.id = 123
        document.originalFilename = "scan 0042.pdf"
        return NamingContext(
            document: document,
            correspondent: correspondent.map { Correspondent(id: 1, name: $0) },
            tags: tags.enumerated().map { Tag(id: $0.offset + 1, name: $0.element) }
        )
    }

    @Test func defaultNameIsPaddedId() {
        let namer = FileNamer(format: nil, timeZone: utc)
        #expect(namer.filename(for: context(), fileExtension: ".pdf") == "0000123.pdf")
        #expect(namer.filename(for: context(), fileExtension: ".pdf", counter: 2) == "0000123_02.pdf")
        #expect(namer.filename(for: context(), fileExtension: ".jpg", version: 1) == "0000123_v1.jpg")
    }

    @Test func formatWithPlaceholders() {
        let namer = FileNamer(format: "{{ created_year }}/{{ correspondent }}/{{ title }}", timeZone: utc)
        #expect(namer.filename(for: context(), fileExtension: ".pdf") == "2019/My bank/Statement January.pdf")
        #expect(namer.filename(for: context(), fileExtension: ".pdf", archive: true) == "2019/My bank/Statement January.pdf")
    }

    @Test func documentRelatedObjectsRenderAsNames() {
        // Paperless-ngx MatchingModelContext: the object prints its name and keeps id, name and path.
        let namer = FileNamer(format: "{{ document.correspondent }}/{{ document.correspondent.id }}-{{ document.correspondent.name }}", timeZone: utc)
        #expect(namer.filename(for: context(), fileExtension: ".pdf") == "My bank/1-My bank.pdf")
        let missing = FileNamer(format: "{% if document.document_type %}typed{% else %}untyped{% endif %}/{{ title }}", timeZone: utc)
        #expect(missing.filename(for: context(), fileExtension: ".pdf") == "untyped/Statement January.pdf")
    }

    @Test func legacyFormatIsConverted() {
        let namer = FileNamer(format: "{created_year}-{created_month}-{created_day} {title}", timeZone: utc)
        #expect(namer.filename(for: context(), fileExtension: ".pdf") == "2019-01-31 Statement January.pdf")
    }

    @Test func missingValuesAndRemoveNone() {
        let keep = FileNamer(format: "{{ correspondent }}/{{ asn }} {{ title }}", timeZone: utc)
        #expect(keep.filename(for: context(correspondent: nil), fileExtension: ".pdf") == "none/none Statement January.pdf")
        let remove = FileNamer(format: "{{ correspondent }}/{{ asn }} {{ title }}", removeNone: true, timeZone: utc)
        #expect(remove.filename(for: context(correspondent: nil), fileExtension: ".pdf") == "Statement January.pdf")
        // Empty placeholders are falsy in conditions.
        let conditional = FileNamer(format: "{% if correspondent %}{{ correspondent }}{% else %}unsorted{% endif %}/{{ title }}", timeZone: utc)
        #expect(conditional.filename(for: context(correspondent: nil), fileExtension: ".pdf") == "unsorted/Statement January.pdf")
    }

    @Test func unsafeCharactersAreReplaced() {
        let namer = FileNamer(format: "{{ correspondent }}/{{ title }}", timeZone: utc)
        #expect(namer.filename(for: context(title: "a/b: c?", correspondent: "x\\y"), fileExtension: ".pdf") == "x-y/a-b- c-.pdf")
    }

    @Test func badTemplatesAndEscapingFallBackToDefault() {
        #expect(FileNamer(format: "{% if %}", timeZone: utc).filename(for: context(), fileExtension: ".pdf") == "0000123.pdf")
        #expect(FileNamer(format: "../../etc/{{ title }}", timeZone: utc).filename(for: context(), fileExtension: ".pdf") == "0000123.pdf")
        #expect(FileNamer(format: "{{ no_such_variable }}", timeZone: utc).filename(for: context(), fileExtension: ".pdf") == "0000123.pdf")
    }

    @Test func tagsAndOriginalName() {
        let namer = FileNamer(format: "{{ tag_list }}/{{ original_name }}", timeZone: utc)
        #expect(namer.filename(for: context(tags: ["tax", "bank"]), fileExtension: ".pdf") == "bank,tax/scan 0042.pdf")
    }

    @Test func multilineTemplateCollapses() {
        let template = """
        somepath/
        {% if document.archive_serial_number >= 201 %}
          asn-201-400
        {% else %}
          asn-000-200
        {% endif %}
        /{{ title }}
        """
        let namer = FileNamer(format: template, timeZone: utc)
        #expect(namer.filename(for: context(asn: 205), fileExtension: ".pdf") == "somepath/asn-201-400/Statement January.pdf")
    }

    @Test func uniqueNamesAvoidExistingFiles() throws {
        let dir = TempDir()
        let namer = FileNamer(format: "{{ title }}", timeZone: utc)
        FileManager.default.createFile(atPath: dir.file("Statement January.pdf").path, contents: Data())
        #expect(namer.uniqueFilename(for: context(), fileExtension: ".pdf", current: nil, root: dir.url) == "Statement January_01.pdf")
        #expect(namer.uniqueFilename(for: context(), fileExtension: ".pdf", current: "Statement January.pdf", root: dir.url) == "Statement January.pdf")
    }

    @Test func ignorePatterns() {
        let patterns = IgnorePatterns(SettingsLoader.defaultIgnorePatterns)
        #expect(patterns.matches(".DS_Store"))
        #expect(patterns.matches("sub/._scan.pdf"))
        #expect(patterns.matches(".stfolder/x"))
        #expect(!patterns.matches("scan.pdf"))
    }
}
