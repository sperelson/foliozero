import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite(.serialized) struct WorkflowTests {
    func makeApp(_ dir: TempDir) throws -> FolioApp {
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"])
        return try FolioApp.open(settings: settings)
    }

    @discardableResult
    func addWorkflow(_ app: FolioApp, name: String, trigger: WorkflowTriggerType, triggerConfig: WorkflowTriggerConfig = .init(), actions: [(WorkflowActionType, WorkflowActionConfig)]) async throws -> Int {
        try await app.database.write { db in
            var workflow = Workflow(name: name)
            try workflow.insert(db)
            var t = WorkflowTrigger(workflowId: workflow.id!, type: trigger, config: triggerConfig)
            try t.insert(db)
            for (index, (type, config)) in actions.enumerated() {
                var action = WorkflowAction(workflowId: workflow.id!, type: type, order: index, config: config)
                try action.insert(db)
            }
            return workflow.id!
        }
    }

    @Test func consumptionStartedAssignsMetadataAndTitleTemplate() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let (tagId, correspondentId) = try await app.database.write { db -> (Int, Int) in
            var tag = Tag(name: "From scanner"); try tag.insert(db)
            var c = Correspondent(name: "City of Cape Town", matchingAlgorithm: .none); try c.insert(db)
            return (tag.id!, c.id!)
        }
        var trigger = WorkflowTriggerConfig()
        trigger.filterFilename = "*rates*"
        var assign = WorkflowActionConfig()
        assign.assignTags = [tagId]
        assign.assignCorrespondent = correspondentId
        assign.assignTitle = "{{ correspondent }} rates {{ created_year }}-{{ created_month }}"
        try await addWorkflow(app, name: "Rates", trigger: .consumption, triggerConfig: trigger, actions: [(.assignment, assign)])

        let file = dir.file("rates-notice.pdf")
        makeTextPDF("Municipal rates account. Statement date 01.07.2026", at: file)
        let document = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        #expect(document.title == "City of Cape Town rates 2026-07")
        #expect(document.correspondentId == correspondentId)
        let tags = try await app.database.read { db in try DocumentStore.tagIds(of: document.id!, in: db) }
        #expect(tags == [tagId])

        // A file that does not match the filename filter is untouched.
        let other = dir.file("letter.pdf")
        makeTextPDF("Hello", at: other)
        let plain = try await app.consumer().consume(ConsumeRequest(file: other, source: .consumeFolder))
        #expect(plain.title == "letter")
        #expect(plain.correspondentId == nil)
    }

    @Test func sourceFilterAndMoveToTrashStopsConsumption() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        var trigger = WorkflowTriggerConfig()
        trigger.sources = [DocumentSource.apiUpload.rawValue]
        try await addWorkflow(app, name: "Reject uploads", trigger: .consumption, triggerConfig: trigger, actions: [(.moveToTrash, .init())])

        let file = dir.file("upload.pdf")
        makeTextPDF("Spam", at: file)
        await #expect(throws: ConsumeError.stoppedByWorkflow("upload.pdf")) {
            try await app.consumer().consume(ConsumeRequest(file: file, source: .apiUpload, deleteSource: true))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Folder consumption is not affected.
        let kept = dir.file("kept.pdf")
        makeTextPDF("Keep", at: kept)
        _ = try await app.consumer().consume(ConsumeRequest(file: kept, source: .consumeFolder))
    }

    @Test func documentAddedMatchesContentAndRemoves() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let (inbox, typeId) = try await app.database.write { db -> (Int, Int) in
            var inbox = Tag(name: "Inbox", isInboxTag: true); try inbox.insert(db)
            var type = DocumentType(name: "Payslip", matchingAlgorithm: .none); try type.insert(db)
            return (inbox.id!, type.id!)
        }
        var trigger = WorkflowTriggerConfig()
        trigger.match = "payslip"
        trigger.matchingAlgorithm = MatchingAlgorithm.any.rawValue
        var assign = WorkflowActionConfig()
        assign.assignDocumentType = typeId
        var removal = WorkflowActionConfig()
        removal.removeTags = [inbox]
        try await addWorkflow(app, name: "Payslips", trigger: .documentAdded, triggerConfig: trigger, actions: [(.assignment, assign), (.removal, removal)])

        let file = dir.file("march.pdf")
        makeTextPDF("Payslip for March 2026", at: file)
        let document = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        #expect(document.documentTypeId == typeId)
        let tags = try await app.database.read { db in try DocumentStore.tagIds(of: document.id!, in: db) }
        #expect(tags.isEmpty)
        let runs = try await app.database.read { db in try WorkflowRun.fetchCount(db) }
        #expect(runs == 1)
    }

    @Test func scheduledTriggerRunsOnceUnlessRecurring() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let tagId = try await app.database.write { db -> Int in
            var tag = Tag(name: "Review"); try tag.insert(db)
            return tag.id!
        }
        var trigger = WorkflowTriggerConfig()
        trigger.scheduleDateField = "created"
        trigger.scheduleOffsetDays = 30
        var assign = WorkflowActionConfig()
        assign.assignTags = [tagId]
        try await addWorkflow(app, name: "Review after 30 days", trigger: .scheduled, triggerConfig: trigger, actions: [(.assignment, assign)])

        let (old, recent) = try await app.database.write { db -> (Int, Int) in
            let old = try DocumentStore.insert(.fixture("old", created: CalendarDate(year: 2026, month: 1, day: 1)), in: db)
            let recent = try DocumentStore.insert(.fixture("recent", created: CalendarDate(year: 2026, month: 11, day: 1)), in: db)
            return (old.id!, recent.id!)
        }
        let now = CalendarDate(year: 2026, month: 11, day: 7).startDate(in: TimeZone(identifier: "UTC")!)
        await WorkflowEngine(app: app).runScheduled(now: now)
        await WorkflowEngine(app: app).runScheduled(now: now)
        let (oldTags, recentTags, runs) = try await app.database.read { db in
            (try DocumentStore.tagIds(of: old, in: db), try DocumentStore.tagIds(of: recent, in: db), try WorkflowRun.fetchCount(db))
        }
        #expect(oldTags == [tagId])
        #expect(recentTags.isEmpty)
        #expect(runs == 1)
    }

    @Test func customFieldQueryFilter() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let (fieldId, tagId) = try await app.database.write { db -> (Int, Int) in
            var field = CustomField(name: "Paid", dataType: .boolean); try field.insert(db)
            var tag = Tag(name: "Settled"); try tag.insert(db)
            return (field.id!, tag.id!)
        }
        var trigger = WorkflowTriggerConfig()
        trigger.filterCustomFieldQuery = #"["Paid", "exact", true]"#
        var assign = WorkflowActionConfig()
        assign.assignTags = [tagId]
        try await addWorkflow(app, name: "Paid", trigger: .documentUpdated, triggerConfig: trigger, actions: [(.assignment, assign)])

        let (paid, unpaid) = try await app.database.write { db -> (Int, Int) in
            let a = try DocumentStore.insert(.fixture("a"), in: db)
            let b = try DocumentStore.insert(.fixture("b"), in: db)
            try CustomFieldValues.set(fieldId: fieldId, value: .bool(true), documentId: a.id!, in: db)
            try CustomFieldValues.set(fieldId: fieldId, value: .bool(false), documentId: b.id!, in: db)
            return (a.id!, b.id!)
        }
        await WorkflowEngine(app: app).documentUpdated(paid)
        await WorkflowEngine(app: app).documentUpdated(unpaid)
        let (paidTags, unpaidTags) = try await app.database.read { db in
            (try DocumentStore.tagIds(of: paid, in: db), try DocumentStore.tagIds(of: unpaid, in: db))
        }
        #expect(paidTags == [tagId])
        #expect(unpaidTags.isEmpty)
    }

    @Test func internalHostsAreDetected() {
        #expect(NetworkPolicy.isInternal(host: "localhost"))
        #expect(NetworkPolicy.isInternal(host: "127.0.0.1"))
        #expect(NetworkPolicy.isInternal(host: "192.168.1.10"))
        #expect(NetworkPolicy.isInternal(host: "10.0.0.1"))
        #expect(NetworkPolicy.isInternal(host: "[::1]"))
        #expect(!NetworkPolicy.isInternal(host: "8.8.8.8"))
    }
}
