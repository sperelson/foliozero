import Foundation
import FolioParsing
import GRDB

/// The application configuration that `/api/config/` stores (Paperless-ngx
/// `ApplicationConfiguration`) applied on top of the settings.
///
/// Mirrors Paperless-ngx `OcrConfig`, `BarcodeConfig` and `GeneralConfig`: a stored value wins
/// when Python would treat it as set (`value or setting`), so null, empty strings, zero and
/// empty mappings fall back to the setting. Booleans apply whenever they are not null.
/// Unknown choices also fall back, because the API rejects them on the way in.
///
/// Fields for OCRmyPDF options that Vision and Tesseract have no equivalent for
/// (`unpaper_clean`, `deskew`, `rotate_pages_threshold`, `max_image_pixels`,
/// `color_conversion_strategy`, `user_args`) are stored but not applied.
extension Settings {
    public func applyingApplicationConfiguration(_ object: [String: JSONValue]) -> Settings {
        var s = self
        func string(_ key: String) -> String? {
            guard let value = object[key], case .string(let text) = value else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        func nonZeroInt(_ key: String) -> Int? {
            guard let value = object[key]?.intValue, value != 0 else { return nil }
            return value
        }
        func nonZeroDouble(_ key: String) -> Double? {
            guard let value = object[key]?.doubleValue, value != 0 else { return nil }
            return value
        }
        func bool(_ key: String) -> Bool? {
            guard let value = object[key], !value.isNull else { return nil }
            return value.boolValue
        }

        // OcrConfig
        if let type = string("output_type") { s.ocrOutputPDFA = type.lowercased().hasPrefix("pdfa") }
        if let pages = nonZeroInt("pages") { s.ocrPages = pages }
        if let language = string("language") {
            let languages = language.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !languages.isEmpty { s.ocrLanguage = languages }
        }
        if let mode = string("mode").flatMap(OCRMode.init(rawValue:)) { s.ocrMode = mode }
        if let archive = string("archive_file_generation").flatMap(ArchiveMode.init(rawValue:)) { s.archiveFileGeneration = archive }
        if let dpi = nonZeroInt("image_dpi") { s.ocrImageDPI = dpi }
        if let rotate = bool("rotate_pages") { s.ocrRotatePages = rotate }

        // GeneralConfig
        if let title = string("app_title") { s.appTitle = title }
        if let logo = string("app_logo") { s.appLogo = logo }

        // BarcodeConfig
        if let v = bool("barcodes_enabled") { s.consumerEnableBarcodes = v }
        if let v = bool("barcode_enable_tiff_support") { s.consumerBarcodeTIFFSupport = v }
        if let v = string("barcode_string") { s.consumerBarcodeString = v }
        if let v = bool("barcode_retain_split_pages") { s.consumerBarcodeRetainSplitPages = v }
        if let v = bool("barcode_enable_asn") { s.consumerEnableASNBarcode = v }
        if let v = string("barcode_asn_prefix") { s.consumerASNBarcodePrefix = v }
        if let v = nonZeroDouble("barcode_upscale") { s.consumerBarcodeUpscale = v }
        if let v = nonZeroInt("barcode_dpi") { s.consumerBarcodeDPI = v }
        if let v = nonZeroInt("barcode_max_pages") { s.consumerBarcodeMaxPages = v }
        if let v = bool("barcode_enable_tag") { s.consumerEnableTagBarcode = v }
        if case .object(let mapping)? = object["barcode_tag_mapping"], !mapping.isEmpty {
            s.consumerTagBarcodeMapping = mapping.compactMapValues { $0.stringValue }
        }
        if let v = bool("barcode_tag_split") { s.consumerTagBarcodeSplit = v }
        if let v = bool("barcode_store_values") { s.consumerStoreBarcodeValues = v }
        return s
    }
}

extension FolioApp {
    /// The stored application configuration, or an empty object when there is none.
    public func applicationConfiguration() -> [String: JSONValue] {
        let stored = try? database.read { db in
            try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")
        }
        guard let stored = stored ?? nil, let data = stored.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    /// `settings` with the application configuration applied, read from the database now.
    /// Paperless-ngx reads its configuration each time a parser or consumer starts, so a
    /// change in the web UI applies to the next document without a restart.
    public func effectiveSettings() -> Settings {
        settings.applyingApplicationConfiguration(applicationConfiguration())
    }
}
