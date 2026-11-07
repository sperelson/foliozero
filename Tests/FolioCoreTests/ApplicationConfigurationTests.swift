import Foundation
import GRDB
import Testing
@testable import FolioCore

/// The application configuration (`/api/config/`) overrides settings, as Paperless-ngx
/// `OcrConfig`, `BarcodeConfig` and `GeneralConfig` do.
@Suite struct ApplicationConfigurationTests {
    func settings(_ dir: TempDir, _ overrides: [String: String] = [:]) throws -> Settings {
        try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: overrides)
    }

    @Test func storedValuesOverrideSettings() throws {
        let dir = TempDir()
        let base = try settings(dir, ["CONSUMER_ENABLE_BARCODES": "true", "OCR_ROTATE_PAGES": "true"])
        let s = base.applyingApplicationConfiguration([
            "output_type": .string("pdfa-2"), "pages": .int(3), "language": .string("deu+eng"), "mode": .string("redo"),
            "archive_file_generation": .string("never"), "image_dpi": .int(300), "rotate_pages": .bool(false),
            "app_title": .string("Archive"), "app_logo": .string("logo/archive.png"),
            "barcodes_enabled": .bool(false), "barcode_enable_tiff_support": .bool(true), "barcode_string": .string("SPLIT"),
            "barcode_retain_split_pages": .bool(true), "barcode_enable_asn": .bool(true), "barcode_asn_prefix": .string("DOC"),
            "barcode_upscale": .double(1.5), "barcode_dpi": .int(600), "barcode_max_pages": .int(2),
            "barcode_enable_tag": .bool(true), "barcode_tag_mapping": .object(["TAG:(.*)": .string("\\g<1>")]),
            "barcode_tag_split": .bool(true), "barcode_store_values": .bool(true),
        ])
        #expect(s.ocrOutputPDFA)
        #expect(s.ocrPages == 3)
        #expect(s.ocrLanguage == ["deu", "eng"])
        #expect(s.ocrMode == .redo)
        #expect(s.archiveFileGeneration == .never)
        #expect(s.ocrImageDPI == 300)
        #expect(s.ocrRotatePages == false)
        #expect(s.appTitle == "Archive")
        #expect(s.appLogo == "logo/archive.png")
        #expect(s.consumerEnableBarcodes == false)
        #expect(s.consumerBarcodeTIFFSupport)
        #expect(s.consumerBarcodeString == "SPLIT")
        #expect(s.consumerBarcodeRetainSplitPages)
        #expect(s.consumerEnableASNBarcode)
        #expect(s.consumerASNBarcodePrefix == "DOC")
        #expect(s.consumerBarcodeUpscale == 1.5)
        #expect(s.consumerBarcodeDPI == 600)
        #expect(s.consumerBarcodeMaxPages == 2)
        #expect(s.consumerEnableTagBarcode)
        #expect(s.consumerTagBarcodeMapping == ["TAG:(.*)": "\\g<1>"])
        #expect(s.consumerTagBarcodeSplit)
        #expect(s.consumerStoreBarcodeValues)
        // The parser options follow.
        let options = s.parseOptions(scratchDirectory: dir.url)
        #expect(options.ocrMode == .redo)
        #expect(options.archiveMode == .never)
        #expect(options.languages == ["deu", "eng"])
        #expect(options.ocrPages == 3)
        #expect(options.pdfA)
    }

    @Test func emptyValuesFallBackToSettings() throws {
        let dir = TempDir()
        let base = try settings(dir, [
            "OCR_OUTPUT_TYPE": "pdfa", "OCR_PAGES": "5", "OCR_LANGUAGE": "eng", "OCR_MODE": "force",
            "CONSUMER_BARCODE_STRING": "PATCHT", "CONSUMER_BARCODE_DPI": "300", "APP_TITLE": "From settings",
        ])
        // Python `or`: null, "", 0 and unknown choices keep the setting.
        let s = base.applyingApplicationConfiguration([
            "output_type": .null, "pages": .int(0), "language": .string(""), "mode": .string("bogus"),
            "barcode_string": .string(""), "barcode_dpi": .null, "app_title": .string(""), "barcode_tag_mapping": .object([:]),
        ])
        #expect(s.ocrOutputPDFA)
        #expect(s.ocrPages == 5)
        #expect(s.ocrLanguage == ["eng"])
        #expect(s.ocrMode == .force)
        #expect(s.consumerBarcodeString == "PATCHT")
        #expect(s.consumerBarcodeDPI == 300)
        #expect(s.appTitle == "From settings")
        // Plain pdf turns a PDF/A setting off; booleans apply when not null.
        let pdf = base.applyingApplicationConfiguration(["output_type": .string("pdf"), "barcodes_enabled": .null])
        #expect(pdf.ocrOutputPDFA == false)
        #expect(pdf.consumerEnableBarcodes == base.consumerEnableBarcodes)
    }

    @Test func effectiveSettingsReadTheDatabaseEachTime() throws {
        let dir = TempDir()
        let app = try FolioApp.open(settings: try settings(dir, ["OCR_MODE": "auto"]))
        #expect(app.effectiveSettings().ocrMode == .auto)
        try app.database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_config(id, config) VALUES (1, ?)", arguments: [#"{"mode": "off"}"#])
        }
        #expect(app.effectiveSettings().ocrMode == .off)
        try app.database.write { db in
            try db.execute(sql: "UPDATE app_config SET config = ? WHERE id = 1", arguments: [#"{"mode": null}"#])
        }
        #expect(app.effectiveSettings().ocrMode == .auto)
        // The startup settings never change.
        #expect(app.settings.ocrMode == .auto)
    }
}
