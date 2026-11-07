import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

/// Broadcasts `documents_deleted` and `document_updated` events to open `/ws/status/` connections.
actor StatusHub {
    private struct Subscriber {
        var continuation: AsyncStream<JSON>.Continuation
        var access: AccessContext
    }

    private var subscribers: [UUID: Subscriber] = [:]

    func subscribe(_ continuation: AsyncStream<JSON>.Continuation, access: AccessContext) -> UUID {
        let id = UUID()
        subscribers[id] = Subscriber(continuation: continuation, access: access)
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    var count: Int { subscribers.count }

    /// Sends to everyone, or only to those `PermissionsData` allows (owner, view users, view groups).
    func publish(_ payload: JSON, ownerId: Int? = nil, users: [Int] = [], groups: [Int] = [], everyone: Bool = false) {
        for subscriber in subscribers.values {
            let access = subscriber.access
            let allowed = everyone || access.isSuperuser || ownerId == nil || ownerId == access.userId
                || users.contains(access.userId) || !Set(groups).isDisjoint(with: access.groupIds)
            if allowed { subscriber.continuation.yield(payload) }
        }
    }
}

extension API {
    /// Decides whether to upgrade `GET /ws/status/` to a WebSocket: session (or header) authentication and a
    /// same-site Origin, as Paperless-ngx's `AuthMiddlewareStack` and `AllowedHostsOriginValidator` require.
    func statusSocketUpgrade(_ head: HTTPRequest) async -> ShouldUpgradeResult<WebSocketDataHandler<HTTP1WebSocketUpgradeChannel.Context>> {
        let path = head.path.map { String($0.prefix { $0 != "?" }) } ?? ""
        guard path == "/ws/status" || path == "/ws/status/" else { return .dontUpgrade }
        if let origin = head.headerFields[.origin], !isTrustedOrigin(origin, host: head.authority), !Self.sameHost(origin, head.authority) {
            return .dontUpgrade
        }
        guard let auth = try? await authenticate(head: head, isAPI: false) else { return .dontUpgrade }
        return .upgrade([:]) { inbound, outbound, _ in
            await self.runStatusSocket(access: auth.access, inbound: inbound, outbound: outbound)
        }
    }

    /// Origin and Host name the same machine (scheme and port aside).
    static func sameHost(_ origin: String, _ authority: String?) -> Bool {
        guard let originHost = URL(string: origin)?.host?.lowercased(), let authority else { return false }
        let host = URL(string: "http://" + authority)?.host?.lowercased()
        return originHost == host
    }

    /// One `/ws/status/` connection: consume task progress (polled from the task table and queue),
    /// hub events, and a heartbeat every 30 seconds, until the client closes.
    func runStatusSocket(access: AccessContext, inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter) async {
        let (events, continuation) = AsyncStream<JSON>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        let subscription = await statusHub.subscribe(continuation, access: access)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    do { try await outbound.writeTextMessage(event.serialized()) } catch { return }
                }
            }
            group.addTask {
                do { for try await _ in inbound {} } catch {}
            }
            group.addTask { await self.pollTaskProgress(access: access, into: continuation) }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { break }
                    continuation.yield(["type": "heartbeat"])
                }
            }
            _ = await group.next()
            continuation.finish()
            group.cancelAll()
        }
        await statusHub.unsubscribe(subscription)
    }

    /// Consumer progress in Paperless-ngx's `status_update` shape (STARTED, WORKING, SUCCESS, FAILED).
    func pollTaskProgress(access: AccessContext, into continuation: AsyncStream<JSON>.Continuation) async {
        let since = QueryFilters.timestamp(Date().addingTimeInterval(-1))
        let visibility: SQL = access.isSuperuser ? "1" : "(t.owner_id IS NULL OR t.owner_id = \(access.userId))"
        var sent: [String: String] = [:]
        while !Task.isCancelled {
            let tasks = (try? await read { db in
                try TaskRecord.fetchAll(db, SQLRequest<TaskRecord>(literal: """
                    SELECT t.* FROM tasks t WHERE t.task_type = 'consume_file'
                      AND (t.status IN ('pending', 'started') OR t.date_done >= \(since)) AND \(visibility)
                    ORDER BY t.id
                    """))
            }) ?? []
            for task in tasks {
                var status = "STARTED", progress = 0, message = "new_file"
                var documentId: Int?
                switch task.status {
                case .pending:
                    break
                case .started:
                    status = "WORKING"
                    if let (percent, text) = await queue.progress(of: task.taskId) {
                        progress = percent
                        message = Self.statusMessageKey(text)
                    } else {
                        message = "parsing_document"
                    }
                case .success:
                    status = "SUCCESS"; progress = 100; message = "finished"
                    documentId = task.relatedDocumentId ?? task.resultData?["document_id"].flatMap { Int($0) }
                case .failure, .revoked:
                    status = "FAILED"; progress = 100; message = task.resultMessage ?? "failed"
                }
                let key = "\(status):\(progress):\(message)"
                guard sent[task.taskId] != key else { continue }
                sent[task.taskId] = key
                continuation.yield(.object(JSONObject([
                    ("type", "status_update"),
                    ("data", .object(JSONObject([
                        ("filename", JSON(task.inputData?["filename"])), ("task_id", .string(task.taskId)),
                        ("current_progress", .int(progress)), ("max_progress", 100), ("status", .string(status)),
                        ("message", .string(message)), ("document_id", JSON(documentId)), ("owner_id", JSON(task.ownerId)),
                        ("users_can_view", []), ("groups_can_view", []),
                    ]))),
                ])))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Maps consumer progress text to the frontend's message keys.
    static func statusMessageKey(_ text: String) -> String {
        switch text.lowercased() {
        case "consumption started": "new_file"
        case "parsing document": "parsing_document"
        case "storing document": "save_document"
        case "finished": "finished"
        default: text
        }
    }

    /// `document_updated` for viewers of the document.
    func publishDocumentUpdated(_ id: Int) async {
        guard await statusHub.count > 0 else { return }
        guard let (document, grants) = try? await read({ db -> (Document, PermissionSet)? in
            guard let document = try Document.fetchOne(db, key: id) else { return nil }
            return (document, try PermissionSet.load(objectType: Document.objectType, objectId: id, in: db))
        }) else { return }
        let users = Array(Set(grants.view.users + grants.change.users)).sorted()
        let groups = Array(Set(grants.view.groups + grants.change.groups)).sorted()
        let payload: JSON = .object(JSONObject([
            ("type", "document_updated"),
            ("data", .object(JSONObject([
                ("document_id", .int(id)), ("modified", datetime(document.modified)), ("owner_id", JSON(document.ownerId)),
                ("users_can_view", JSON(users)), ("groups_can_view", JSON(groups)),
            ]))),
        ]))
        await statusHub.publish(payload, ownerId: document.ownerId, users: users, groups: groups)
    }

    func publishDocumentsDeleted(_ ids: [Int]) async {
        guard !ids.isEmpty else { return }
        await statusHub.publish(["type": "documents_deleted", "data": ["documents": JSON(ids)]], everyone: true)
    }
}
