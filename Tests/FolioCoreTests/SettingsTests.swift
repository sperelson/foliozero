import Foundation
import Testing
@testable import FolioCore

@Suite struct SettingsTests {
    @Test func defaultsUnderHome() throws {
        let settings = try SettingsLoader.load(home: "/tmp/fz-home", environment: [:])
        #expect(settings.dataDir.path == "/tmp/fz-home/data")
        #expect(settings.mediaRoot.path == "/tmp/fz-home/media")
        #expect(settings.consumptionDir.path == "/tmp/fz-home/consume")
        #expect(settings.ocrMode == .auto)
        #expect(settings.archiveFileGeneration == .auto)
        #expect(settings.port == 8000)
        #expect(settings.dateOrder == .DMY)
        #expect(settings.ocrLanguage == ["eng"])
        #expect(settings.emptyTrashDelayDays == 30)
    }

    @Test func precedence() throws {
        let env = ["FOLIOZERO_PORT": "8100", "PAPERLESS_PORT": "8200", "PAPERLESS_OCR_MODE": "force"]
        let settings = try SettingsLoader.load(home: "/tmp/fz-home", environment: env, overrides: ["OCR_LANGUAGE": "eng+afr"])
        #expect(settings.port == 8100)
        #expect(settings.ocrMode == .force)
        #expect(settings.ocrLanguage == ["eng", "afr"])
    }

    @Test func configFileValuesAndPaperlessNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let conf = dir.appendingPathComponent("foliozero.conf")
        try """
        # comment
        PAPERLESS_CONSUMER_RECURSIVE=true
        FOLIOZERO_TIME_ZONE="Africa/Johannesburg"
        export PAPERLESS_FILENAME_FORMAT={{ created_year }}/{{ title }}  # trailing comment
        """.write(to: conf, atomically: false, encoding: .utf8)

        let settings = try SettingsLoader.load(home: dir.path, environment: ["FOLIOZERO_REPORTED_VERSION": "2.20.0"])
        #expect(settings.raw["REPORTED_VERSION"] == "2.20.0")
        #expect(settings.raw["CONSUMER_RECURSIVE"] == "true")
        #expect(settings.consumerRecursive)
        #expect(settings.timeZone.identifier == "Africa/Johannesburg")
        #expect(settings.filenameFormat == "{{ created_year }}/{{ title }}")
    }

    @Test func invalidValuesThrow() {
        #expect(throws: SettingsError.self) {
            try SettingsLoader.load(home: "/tmp/fz-home", environment: ["FOLIOZERO_PORT": "eighty"])
        }
        #expect(throws: SettingsError.self) {
            try SettingsLoader.load(home: "/tmp/fz-home", environment: ["FOLIOZERO_OCR_MODE": "sometimes"])
        }
    }
}
