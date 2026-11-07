import Foundation
import PDFKit
import Testing
@testable import FolioParsing

enum EmailFixtures {
    static func pdfAttachment() throws -> Data {
        let dir = try FixtureFactory.makeDirectory("emailpdf")
        let url = dir.appendingPathComponent("invoice.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Attached invoice"]], to: url)
        return try Data(contentsOf: url)
    }

    static func pngData() -> Data {
        ImageUtilities.pngData(FixtureFactory.textImage(["IMG"], width: 40, height: 20, fontSize: 12))!
    }

    /// multipart/mixed: multipart/related(multipart/alternative(text QP, html), inline PNG), PDF attachment.
    static func richMessage() throws -> Data {
        let pdf = try pdfAttachment().base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let png = pngData().base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let message = """
        Return-Path: <billing@example.com>
        Received: from mx.example.com by mail.example.org; Mon, 2 Nov 2026 10:00:05 +0200
        From: =?UTF-8?Q?J=C3=BCrgen_M=C3=BCller?= <billing@example.com>
        To: "Doe, Jane" <jane@example.org>, bob@example.org (Bob Smith)
        Cc: Accounts: acc1@example.org, acc2@example.org;
        Subject: =?UTF-8?B?UmVjaG51bmcgTnIuIDQ3MTE=?= =?ISO-8859-1?Q?_f=FCr_Oktober?=
        Date: Mon, 2 Nov 2026 10:00:00 +0200 (SAST)
        Message-ID: <abc123@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer-boundary"

        This is the preamble.
        --outer-boundary
        Content-Type: multipart/related; boundary=related-b

        --related-b
        Content-Type: multipart/alternative;
         boundary="alt-b"

        --alt-b
        Content-Type: text/plain; charset=windows-1252
        Content-Transfer-Encoding: quoted-printable

        Guten Tag,=0D
        Ihre Rechnung =FCber 120 =80 ist f=E4llig. Ein sehr langer Satz, der weich =
        umbrochen wird.
        --alt-b
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(Data("<html><head><style>p { color: #333 }</style><script>alert(1)</script></head><body><p>Guten Tag, <b>Ihre Rechnung</b> HTMLMARKER-31</p><img src=\"cid:logo@example\"></body></html>".utf8).base64EncodedString())
        --alt-b--
        --related-b
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <logo@example>
        Content-Disposition: inline

        \(png)
        --related-b--
        --outer-boundary
        Content-Type: application/pdf; name="=?UTF-8?Q?Rechnung_4711.pdf?="
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment;
         filename*0*=UTF-8''Rechnung%20Nr.%20;
         filename*1*=%E2%84%96%204711.pdf

        \(pdf)
        --outer-boundary--
        Epilogue.
        """
        return Data(message.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }
}

@Suite("Email")
struct EmailTests {
    @Test func parsesHeadersBodiesAndAttachments() throws {
        let message = try MIMEMessage.parse(EmailFixtures.richMessage())
        #expect(message.from == MailAddress(name: "Jürgen Müller", address: "billing@example.com"))
        #expect(message.to == [MailAddress(name: "Doe, Jane", address: "jane@example.org"), MailAddress(name: "Bob Smith", address: "bob@example.org")])
        #expect(message.cc.map(\.address) == ["acc1@example.org", "acc2@example.org"])
        #expect(message.subject == "Rechnung Nr. 4711 für Oktober")
        #expect(message.date == Date(timeIntervalSince1970: 1_793_606_400))
        #expect(message.messageID == "abc123@example.com")
        #expect(message.header("subject") == "Rechnung Nr. 4711 für Oktober")
        #expect(message.headers(named: "Received").count == 1)

        let text = try #require(message.textBody)
        #expect(text.contains("Ihre Rechnung über 120 € ist fällig."))
        #expect(text.contains("der weich umbrochen wird."))
        #expect(message.htmlBody?.contains("HTMLMARKER-31") == true)

        #expect(message.attachments.count == 2)
        let logo = try #require(message.attachments.first { $0.contentId == "logo@example" })
        #expect(logo.disposition == .inline)
        #expect(logo.contentType == "image/png")
        #expect(logo.data == EmailFixtures.pngData())
        let pdf = try #require(message.attachments.first { $0.contentType == "application/pdf" })
        #expect(pdf.filename == "Rechnung Nr. № 4711.pdf")
        #expect(pdf.disposition == .attachment)
        #expect(pdf.data.starts(with: Data("%PDF".utf8)))
        #expect(PDFDocument(data: pdf.data)?.string?.contains("Attached invoice") == true)
    }

    @Test func simpleLFOnlyMessage() throws {
        let raw = """
        From: alice@example.com
        To: bob@example.com
        Subject: Plain note
        Date: 5 Jan 26 07:08 GMT
        Content-Type: text/plain; charset="iso-8859-1"
        Content-Transfer-Encoding: 8bit

        """
        var data = Data(raw.utf8)
        data.append(0x0A) // blank line ends the header block
        data.append(contentsOf: [0x43, 0x61, 0x66, 0xE9, 0x0A]) // "Café" in Latin-1
        let message = try MIMEMessage.parse(data)
        #expect(message.from?.address == "alice@example.com")
        #expect(message.from?.name == nil)
        #expect(message.textBody == "Café\n")
        #expect(message.htmlBody == nil)
        #expect(message.attachments.isEmpty)
        #expect(message.date == Date(timeIntervalSince1970: 1_767_596_880))
    }

    @Test func headerHelpers() {
        #expect(EncodedWords.decode("=?utf-8?q?caf=C3=A9?= =?utf-8?q?_au_lait?=") == "café au lait")
        #expect(EncodedWords.decode("Re: =?ISO-8859-15?Q?=A4uro?= deal") == "Re: €uro deal")
        #expect(EncodedWords.decode("no encoding") == "no encoding")
        let params = HeaderParameters.parse("attachment; filename*=iso-8859-1'de'F%FCr%20dich.txt; size=12")
        #expect(params.value == "attachment")
        #expect(params.parameters["filename"] == "Für dich.txt")
        #expect(params.parameters["size"] == "12")
        let quoted = HeaderParameters.parse("text/plain; name=\"a; \\\"b\\\".txt\"; charset=UTF-8")
        #expect(quoted.parameters["name"] == "a; \"b\".txt")
        #expect(quoted.parameters["charset"] == "UTF-8")
        #expect(RFC5322Date.parse("Tue, 3 Nov 2026 09:15:30 -0500") == Date(timeIntervalSince1970: 1_793_715_330))
        #expect(RFC5322Date.parse("not a date") == nil)
        #expect(Charsets.decode(Data([0xA4]), charset: "iso-8859-15") == "€")
        #expect(Charsets.decode(Data([0x80]), charset: "us-ascii") == "€")
        #expect(throws: MIMEError.self) { try MIMEMessage.parse(Data()) }
    }

    @Test func emailParserBuildsTextAndArchive() async throws {
        let dir = try FixtureFactory.makeDirectory("email")
        let url = dir.appendingPathComponent("invoice.eml")
        try EmailFixtures.richMessage().write(to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == "message/rfc822")
        let parser = try #require(StandardParsers.makeRegistry().parser(for: "message/rfc822"))
        let result = try await parser.parse(file: url, mimeType: "message/rfc822", options: FixtureFactory.options(dir))

        #expect(result.text.hasPrefix("Subject: Rechnung Nr. 4711 für Oktober\n\nFrom: Jürgen Müller <billing@example.com>"))
        #expect(result.text.contains("To: Doe, Jane <jane@example.org>, Bob Smith <bob@example.org>"))
        #expect(result.text.contains("Attachments: Rechnung Nr. № 4711.pdf ("))
        #expect(result.text.contains("Ihre Rechnung über 120 €"))
        #expect(result.suggestedTitle == "Rechnung Nr. 4711 für Oktober")
        #expect(result.metadataDate == Date(timeIntervalSince1970: 1_793_606_400))
        #expect(result.metadata.contains { $0.prefix == "header" && $0.key == "Message-ID" })

        let archive = try #require(result.archiveFile)
        let text = pdfString(archive)
        #expect(text.contains("Rechnung Nr. 4711 für Oktober"), "archive: \(text.prefix(400))")
        #expect(text.contains("HTMLMARKER-31"), "HTML body is rendered")
        #expect(!text.contains("alert(1)"))
        #expect(isJPEG(result.thumbnailFile))
    }

    @Test func plainTextEmailFallsBackToTextLayout() async throws {
        let dir = try FixtureFactory.makeDirectory("emailtext")
        let archive = dir.appendingPathComponent("plain.pdf")
        let pages = try await MainActor.run {
            try AttributedTextPDF.write(
                AttributedTextPDF.plainDocument(heading: [("Subject", "Layout check")], body: String(repeating: "Line of body text LAYOUT-77\n", count: 150)),
                to: archive
            )
        }
        #expect(pages >= 2)
        let text = pdfString(archive)
        #expect(text.contains("Layout check"))
        #expect(text.components(separatedBy: "LAYOUT-77").count == 151)
    }
}
