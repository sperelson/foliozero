import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird

/// AI suggestions, document chat and similar documents (Paperless-ngx `ai_suggestions`, `ChatStreamingView`).
extension API {
    var ai: FolioAI { FolioAI.shared(for: app) }

    /// `AIError` as Paperless-ngx answers it: a JSON `{"ai": [...]}` body or plain text.
    static func aiError(_ error: AIError) -> APIError {
        let status = HTTPResponse.Status(code: error.httpStatus)
        if let body = error.paperlessErrorBody {
            var object = JSONObject()
            for key in body.keys.sorted() { object[key] = JSON(body[key] ?? []) }
            return APIError(status: status, body: .json(.object(object)))
        }
        return APIError(status: status, body: .text(error.description))
    }

    func aiEnabled() -> Bool {
        (try? ai.config().enabled) ?? false
    }

    /// `GET /api/documents/{id}/ai_suggestions/`.
    func aiSuggestions(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        try await read { db in
            guard let document = try Document.fetchOne(db, key: id) else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText() }
        }
        guard aiEnabled() else { throw APIError.badRequestText("AI is required for this feature") }
        do {
            let suggestions = try await ai.suggestions.suggestions(documentId: id, context: access)
            var response = Response.json(.object(Self.encodedObject(suggestions)))
            response.headers[.cacheControl] = "no-cache"
            return response
        } catch let error as AIError {
            throw Self.aiError(error)
        }
    }

    /// `POST /api/documents/chat/` `{q, document_id?}`: the answer as `text/event-stream`.
    func documentChat(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        guard aiEnabled() else { throw APIError.badRequestText("AI is required for this feature") }
        let data = try request.data()
        guard let question = data["q"]?.string, !question.isEmpty else {
            throw APIError.field("q", data.has("q") ? "This field may not be blank." : APIError.requiredField)
        }
        guard question.count <= AIChat.maxQuestionLength else {
            throw APIError.field("q", "Ensure this field has no more than \(AIChat.maxQuestionLength) characters.")
        }
        let documentId = try data.optionalInt("document_id")
        if let documentId {
            try await read { db in
                guard let document = try Document.fetchOne(db, key: documentId) else { throw APIError.badRequestText("Document not found") }
                guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText() }
            }
        }
        let answer: AIChat.Response
        do {
            answer = try await ai.chat.ask(question, documentId: documentId, context: access)
        } catch AIError.documentNotFound {
            throw APIError.badRequestText("Document not found")
        } catch let error as AIError {
            throw Self.aiError(error)
        }
        let pieces = answer.paperlessBody(logger: logger)
        let body = ResponseBody { writer in
            for await piece in pieces {
                try await writer.write(ByteBuffer(string: piece))
            }
            try await writer.finish(nil)
        }
        var headers: HTTPFields = [:]
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        if let session = request.auth?.session {
            var response = Response(status: .ok, headers: headers, body: body)
            response.setCookie(Cookie(name: csrfCookieName, value: session.csrfToken, maxAge: settings.sessionCookieAge, path: "/", httpOnly: false, sameSite: .lax))
            return response
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    /// `GET /api/documents/{id}/similar/`: documents whose content is close in the LLM index.
    func similarDocuments(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        guard aiEnabled() else { throw APIError.badRequestText("AI is required for this feature") }
        let limit = min(max(request.query.int("limit") ?? 10, 1), 100)
        do {
            let similar = try await ai.index.similarDocuments(documentId: id, context: access, limit: limit)
            return .json(.array(similar.map { ["id": .int($0.id), "score": .double($0.score)] }))
        } catch AIError.documentNotFound {
            throw APIError.notFound("Document")
        } catch AIError.permissionDenied {
            throw APIError.forbiddenText()
        } catch let error as AIError {
            throw Self.aiError(error)
        }
    }

    /// `/api/status/` `llmindex_*` fields.
    func llmIndexStatus() async -> (status: String, lastModified: Date?, error: String?) {
        guard let config = try? ai.config(), config.llmIndexEnabled else { return ("DISABLED", nil, nil) }
        let last = try? await read { db in
            try TaskRecord.filter(Column("task_type") == TaskRecord.TaskType.llmIndex.rawValue)
                .order(Column("date_created").desc).fetchOne(db)
        }
        guard let last else { return ("WARNING", nil, "No LLM index update tasks found") }
        if last.status == .failure {
            return ("ERROR", last.dateDone, last.resultData?["error_message"] ?? last.resultMessage)
        }
        return ("OK", last.dateDone, nil)
    }
}
