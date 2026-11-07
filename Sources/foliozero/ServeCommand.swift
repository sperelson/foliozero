import ArgumentParser
import FolioCore
import FolioServer
import Foundation
import Logging

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run FolioZero: HTTP API, consume folder watcher, task workers and scheduled jobs.",
        discussion: "Stops cleanly on Ctrl-C or SIGTERM (launchd). Running tasks get up to 30 seconds to finish."
    )

    @OptionGroup var global: GlobalOptions

    @Flag(help: "Do not watch the consume folder.")
    var noConsumer = false

    func run() async throws {
        let app = try global.openApp(logToFile: true)
        let logger = app.logger
        let settings = app.settings
        logger.info("FolioZero \(FolioZeroCommand.version) starting; data in \(settings.home.path)")

        let queue = TaskQueue(database: app.database, workers: settings.taskWorkers, logger: logger)
        await queue.recoverInterrupted()
        await ShareLinkBundleStore.recoverInterrupted(app: app)

        let scheduler = Scheduler(timeZone: settings.timeZone)
        func schedule(_ name: String, _ cron: String, _ run: @escaping @Sendable () async -> Void) async throws {
            guard let parsed = try CronSchedule.parse(cron) else {
                logger.info("Scheduled job \(name) is disabled")
                return
            }
            await scheduler.add(.init(name: name, schedule: parsed, run: run))
        }
        try await schedule("index_optimize", settings.indexTaskCron) {
            _ = try? await queue.enqueue(type: .indexOptimize, source: .scheduled) { _ in
                try await Maintenance.optimizeIndex(app: app)
                return TaskOutcome(message: "Index optimized")
            }
        }
        try await schedule("empty_trash", settings.emptyTrashTaskCron) {
            _ = try? await queue.enqueue(type: .emptyTrash, source: .scheduled) { _ in
                let count = try await Maintenance.emptyTrash(app: app, olderThan: settings.emptyTrashDelayDays)
                return TaskOutcome(message: "Deleted \(count) documents from the trash")
            }
        }
        try await schedule("train_classifier", settings.trainTaskCron) {
            _ = try? await queue.enqueue(type: .trainClassifier, source: .scheduled) { _ in
                TaskOutcome(message: try await DocumentClassifier.trainAndSave(app: app))
            }
        }
        try await schedule("check_workflows", settings.workflowScheduledTaskCron) {
            _ = try? await queue.enqueue(type: .checkWorkflows, source: .scheduled) { _ in
                await WorkflowEngine(app: app).runScheduled()
                return TaskOutcome(message: "Scheduled workflows checked")
            }
        }
        try await schedule("mail_fetch", settings.emailTaskCron) {
            _ = try? await queue.enqueue(type: .mailFetch, source: .scheduled) { _ in
                let summary = await MailProcessor(app: app, queue: queue, parse: MailProcessor.mimeParser).processAll()
                return TaskOutcome(message: "\(summary.messages) messages checked, \(summary.documents) documents queued"
                    + (summary.errors.isEmpty ? "" : "; errors: " + summary.errors.joined(separator: "; ")))
            }
        }
        let ai = FolioAI.shared(for: app)
        if let aiConfig = try? ai.config(), aiConfig.llmIndexEnabled {
            try await schedule("llm_index", aiConfig.indexTaskCron) {
                _ = try? await queue.enqueue(type: .llmIndex, source: .scheduled) { _ in TaskOutcome(message: try await ai.index.update()) }
            }
        }
        try await schedule("share_link_bundle_cleanup", settings.shareLinkBundleCleanupCron) {
            await ShareLinkBundleStore.cleanupExpired(app: app)
        }
        try await schedule("purge_sessions", "17 * * * *") { await Maintenance.purgeSessions(app: app) }
        await scheduler.start()

        var watcher: FolderWatcher?
        if !noConsumer && !settings.consumerDisable {
            watcher = FolderWatcher(app: app, queue: queue)
            await watcher?.start()
        }

        // No web frontend yet: fetch the Paperless-ngx release in the background. The API runs
        // meanwhile, and the server picks the frontend up as soon as it is in place.
        if FrontendInstaller.shouldAutoInstall(settings: settings) {
            let installer = FrontendInstaller(settings: settings)
            logger.info("The web frontend is missing; downloading Paperless-ngx \(installer.release.version) from GitHub in the background (log: \(installer.logFile.path))")
            Task.detached {
                do {
                    let directory = try await installer.install()
                    logger.info("Web frontend installed in \(directory.path)")
                } catch {
                    logger.error("Web frontend install failed: \(error). It is retried on the next start, or run `foliozero frontend install`.")
                }
            }
        } else if FrontendInstaller.frontendDirectory(settings: settings) == nil {
            logger.warning("No web frontend: FRONTEND_DIR holds no Paperless-ngx static folder, or FRONTEND_AUTO_INSTALL is off")
        }

        // The HTTP server owns SIGINT/SIGTERM (swift-service-lifecycle) and returns after a graceful shutdown.
        var serverError: (any Error)?
        do {
            try await FolioHTTPServer(app: app, queue: queue).run()
        } catch {
            logger.error("HTTP server stopped with an error: \(error)")
            serverError = error
        }
        logger.info("Shutting down")
        await watcher?.stop()
        await scheduler.stop()
        let drained = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await queue.waitUntilIdle(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(30)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !drained { logger.warning("Stopped with tasks still running; they will be marked as interrupted on the next start") }
        logger.info("FolioZero stopped")
        if let serverError { throw serverError }
    }
}
