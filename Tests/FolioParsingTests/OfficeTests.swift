import AppKit
import Foundation
import PDFKit
import Testing
@testable import FolioParsing

enum OfficeFixtures {
    static let docxTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    </Types>
    """

    static let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    </Relationships>
    """

    static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body>
    <w:p><w:r><w:t>Lease agreement for unit 14B</w:t></w:r></w:p>
    <w:p><w:r><w:t xml:space="preserve">Monthly rent: </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>R 9 500</w:t></w:r><w:r><w:tab/><w:t>due</w:t></w:r></w:p>
    <w:p><w:r><w:instrText>PAGE</w:instrText><w:t>Signed in Cape Town</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Tenant</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Landlord</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:sectPr/>
    </w:body>
    </w:document>
    """

    static let coreXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
     xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"
     xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <dc:title>Lease Agreement 14B</dc:title>
    <dc:creator>Thandi Nkosi</dc:creator>
    <dcterms:created xsi:type="dcterms:W3CDTF">2025-02-03T09:00:00Z</dcterms:created>
    </cp:coreProperties>
    """

    static func docx(at url: URL) throws {
        try FixtureFactory.zip([
            ("[Content_Types].xml", docxTypes),
            ("_rels/.rels", rootRels),
            ("word/document.xml", documentXML),
            ("docProps/core.xml", coreXML),
        ], to: url)
    }

    static func xlsx(at url: URL) throws {
        try FixtureFactory.zip([
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            </Types>
            """),
            ("xl/workbook.xml", """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="Budget 2026" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/></sheets>
            </workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
            </Relationships>
            """),
            ("xl/sharedStrings.xml", """
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
            <si><t>Item</t></si><si><t>Amount</t></si><si><r><t>Electri</t></r><r><t>city</t></r><rPh><t>X</t></rPh></si>
            </sst>
            """),
            ("xl/worksheets/sheet1.xml", """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1450.5</v></c><c r="C2" t="b"><v>1</v></c></row>
            <row r="3"><c r="A3" t="inlineStr"><is><t>Water</t></is></c><c r="B3"><f>B2*2</f><v>2901</v></c></row>
            </sheetData></worksheet>
            """),
            ("xl/worksheets/sheet2.xml", """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
            <row r="1"><c r="A1" t="str"><v>Reviewed by finance</v></c></row>
            </sheetData></worksheet>
            """),
        ], to: url)
    }

    static func pptx(at url: URL) throws {
        func slide(_ text: String) -> String {
            """
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """
        }
        try FixtureFactory.zip([
            ("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
            </Types>
            """),
            ("ppt/presentation.xml", "<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"/>"),
            ("ppt/slides/slide10.xml", slide("Tenth slide closing remarks")),
            ("ppt/slides/slide2.xml", slide("Second slide quarterly numbers")),
            ("ppt/slides/slide1.xml", slide("First slide welcome")),
        ], to: url)
    }

    static func odf(at url: URL, mime: String, content: String) throws {
        try FixtureFactory.zip([
            ("mimetype", mime),
            ("content.xml", """
            <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0">
            <office:body>\(content)</office:body></office:document-content>
            """),
            ("meta.xml", """
            <office:document-meta xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
             xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0">
            <office:meta><dc:title>Minutes of the AGM</dc:title><meta:creation-date>2024-08-01T18:00:00</meta:creation-date></office:meta>
            </office:document-meta>
            """),
        ], to: url)
    }
}

@Suite("Office")
struct OfficeTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("office")
    }

    func parse(_ url: URL) async throws -> ParseResult {
        let mime = try FileTypeDetector.mimeType(of: url)
        let parser = try #require(StandardParsers.makeRegistry().parser(for: mime), "no parser for \(mime)")
        #expect(parser.name == "office")
        var office = OfficeParser()
        office.usesLibreOffice = false
        return try await office.parse(file: url, mimeType: mime, options: FixtureFactory.options(dir))
    }

    @Test func docxTextMetadataAndLaidOutArchive() async throws {
        let url = dir.appendingPathComponent("lease.docx")
        try OfficeFixtures.docx(at: url)
        let result = try await parse(url)
        #expect(result.text.contains("Lease agreement for unit 14B"))
        #expect(result.text.contains("Monthly rent: R 9 500 due"))
        #expect(result.text.contains("Signed in Cape Town"))
        #expect(!result.text.contains("PAGE"), "field codes are not text")
        #expect(result.text.contains("Tenant Landlord"))
        #expect(result.suggestedTitle == "Lease Agreement 14B")
        #expect(result.metadataDate == FlexibleDate.parse("2025-02-03T09:00:00Z"))
        #expect(result.metadata.contains { $0.prefix == "dc" && $0.key == "creator" && $0.value == "Thandi Nkosi" })
        let archive = try #require(result.archiveFile, "word processing files are laid out without LibreOffice")
        #expect(pdfString(archive).contains("Lease agreement for unit 14B"))
        #expect(result.pageCount == 1)
        #expect(isJPEG(result.thumbnailFile))
    }

    @Test func xlsxSheetsInWorkbookOrder() async throws {
        let url = dir.appendingPathComponent("budget.xlsx")
        try OfficeFixtures.xlsx(at: url)
        let result = try await parse(url)
        let lines = result.text.components(separatedBy: "\n")
        #expect(lines.contains("Budget 2026"))
        #expect(lines.contains("Item Amount"))
        #expect(lines.contains("Electricity 1450.5 TRUE"), "got \(result.text)")
        #expect(lines.contains("Water 2901"))
        #expect(result.text.range(of: "Budget 2026")!.lowerBound < result.text.range(of: "Reviewed by finance")!.lowerBound)
        #expect(result.archiveFile == nil, "no archive for spreadsheets without LibreOffice")
        #expect(isJPEG(result.thumbnailFile))
    }

    @Test func pptxSlidesInNumericOrder() async throws {
        let url = dir.appendingPathComponent("deck.pptx")
        try OfficeFixtures.pptx(at: url)
        let result = try await parse(url)
        let first = try #require(result.text.range(of: "First slide welcome"))
        let second = try #require(result.text.range(of: "Second slide quarterly numbers"))
        let tenth = try #require(result.text.range(of: "Tenth slide closing remarks"))
        #expect(first.lowerBound < second.lowerBound && second.lowerBound < tenth.lowerBound)
    }

    @Test func openDocumentTextAndSpreadsheet() async throws {
        let odt = dir.appendingPathComponent("minutes.odt")
        try OfficeFixtures.odf(at: odt, mime: "application/vnd.oasis.opendocument.text", content: """
        <office:text><text:h>Annual meeting</text:h><text:p>Present:<text:s text:c="2"/>all<text:tab/>members<text:line-break/>Quorum reached</text:p></office:text>
        """)
        let text = try await parse(odt)
        #expect(text.text.contains("Annual meeting\nPresent: all members\nQuorum reached"), "got \(text.text)")
        #expect(text.suggestedTitle == "Minutes of the AGM")
        #expect(text.metadataDate != nil)

        let ods = dir.appendingPathComponent("levy.ods")
        try OfficeFixtures.odf(at: ods, mime: "application/vnd.oasis.opendocument.spreadsheet", content: """
        <office:spreadsheet><table:table table:name="Levies"><table:table-row>
        <table:table-cell><text:p>Unit</text:p></table:table-cell><table:table-cell><text:p>Levy</text:p></table:table-cell>
        <table:table-cell table:number-columns-repeated="1000"/></table:table-row>
        <table:table-row><table:table-cell><text:p>14B</text:p></table:table-cell><table:table-cell><text:p>2100</text:p></table:table-cell></table:table-row>
        </table:table></office:spreadsheet>
        """)
        let sheet = try await parse(ods)
        #expect(sheet.text.contains("Unit Levy\n14B 2100"), "got \(sheet.text)")
    }

    @Test func rtfAndLegacyDocThroughAppKit() async throws {
        let rtf = dir.appendingPathComponent("letter.rtf")
        let doc = dir.appendingPathComponent("letter.doc")
        try await MainActor.run {
            let string = NSAttributedString(string: "Dear Sir\nYour policy RTF-5531 renews in March.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let range = NSRange(location: 0, length: string.length)
            try string.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf, .title: "Policy renewal"])
                .write(to: rtf)
            try string.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
                .write(to: doc)
        }
        let rtfResult = try await parse(rtf)
        #expect(rtfResult.text.contains("Your policy RTF-5531 renews in March."))
        #expect(rtfResult.suggestedTitle == "Policy renewal")
        #expect(pdfString(try #require(rtfResult.archiveFile)).contains("RTF-5531"))

        #expect(try FileTypeDetector.mimeType(of: doc) == "application/msword")
        let docResult = try await parse(doc)
        #expect(docResult.text.contains("Your policy RTF-5531 renews in March."))
        #expect(docResult.archiveFile != nil)
    }

    @Test func libreOfficeCommand() {
        let args = LibreOffice.conversionArguments(
            input: URL(fileURLWithPath: "/tmp/in/Report Q3.xlsx"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out"),
            profileDirectory: URL(fileURLWithPath: "/tmp/profile dir", isDirectory: true)
        )
        #expect(args.first == "--headless")
        #expect(args.contains("--norestore"))
        #expect(args.contains("-env:UserInstallation=file:///tmp/profile%20dir/"))
        let convert = try! #require(args.firstIndex(of: "--convert-to"))
        #expect(args[convert + 1] == "pdf")
        let outdir = try! #require(args.firstIndex(of: "--outdir"))
        #expect(args[outdir + 1] == "/tmp/out")
        #expect(args.last == "/tmp/in/Report Q3.xlsx")
        #expect(LibreOffice.expectedOutput(for: URL(fileURLWithPath: "/tmp/in/Report Q3.xlsx"), outputDirectory: URL(fileURLWithPath: "/tmp/out")).path
            == "/tmp/out/Report Q3.pdf")
    }

    @Test func libreOfficeMissingIsTolerated() async throws {
        // A configured path that does not exist falls back to the search; on a
        // machine without LibreOffice the parser still produces text.
        let url = dir.appendingPathComponent("lease2.docx")
        try OfficeFixtures.docx(at: url)
        var options = FixtureFactory.options(dir)
        options.libreOfficePath = "/nonexistent/soffice"
        let result = try await OfficeParser().parse(file: url, mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", options: options)
        #expect(result.text.contains("Lease agreement"))
        #expect(result.archiveFile != nil)
    }
}
