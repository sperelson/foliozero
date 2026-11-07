import Foundation
import FolioCore
import Hummingbird

extension API {
    /// Every endpoint. Paths match Paperless-ngx (trailing slashes are optional).
    static func makeRoutes() -> [Route] {
        var routes: [Route] = []
        func add(_ method: HTTPRequest.Method, _ path: String, _ options: Route.Options = [], _ handler: @escaping Handler) {
            routes.append(Route(method, path, options, handler))
        }

        // Index
        add(.get, "/", [.anonymous]) { api, req in try await api.homePage(req) }
        add(.get, "/static/{path...}", [.anonymous]) { api, req in try await api.staticFile(req) }
        add(.get, "/favicon.ico", [.anonymous]) { api, req in try await api.favicon(req) }
        add(.get, "/assets/{path...}", [.anonymous]) { api, req in try await api.frontendAsset(req) }
        add(.get, "/{path...}", [.anonymous, .spa]) { api, req in try await api.singlePageApp(req) }
        add(.get, "/api/") { api, req in try await api.apiIndex(req) }

        // Authentication and profile
        add(.post, "/api/token/", [.anonymous, .csrfExempt]) { api, req in try await api.obtainToken(req) }
        add(.get, "/api/profile/") { api, req in try await api.getProfile(req) }
        add(.patch, "/api/profile/") { api, req in try await api.patchProfile(req) }
        add(.post, "/api/profile/generate_auth_token/") { api, req in try await api.generateToken(req) }
        add(.get, "/api/profile/social_account_providers/") { api, req in try await api.socialAccountProviders(req) }
        add(.post, "/api/profile/disconnect_social_account/") { api, req in try await api.disconnectSocialAccount(req) }
        add(.get, "/api/profile/totp/") { api, req in try await api.getTOTPSetup(req) }
        add(.post, "/api/profile/totp/") { api, req in try await api.activateTOTP(req) }
        add(.delete, "/api/profile/totp/") { api, req in try await api.deleteTOTP(req) }
        add(.post, "/api/users/{id}/deactivate_totp/") { api, req in try await api.deactivateUserTOTP(req) }
        add(.get, "/api/ui_settings/") { api, req in try await api.getUISettings(req) }
        add(.post, "/api/ui_settings/") { api, req in try await api.postUISettings(req) }
        add(.post, "/api/auth/login/", [.anonymous, .csrfExempt]) { api, req in try await api.login(req) }
        add(.post, "/api/auth/logout/", [.anonymous]) { api, req in try await api.logout(req) }
        add(.get, "/accounts/login/", [.anonymous]) { api, req in try await api.loginPage(req) }
        add(.post, "/accounts/login/", [.anonymous, .csrfExempt]) { api, req in try await api.login(req) }
        add(.get, "/accounts/logout/", [.anonymous]) { api, req in try await api.logout(req) }
        add(.post, "/accounts/logout/", [.anonymous]) { api, req in try await api.logout(req) }

        // OpenID Connect (django-allauth `openid_connect` provider and `socialaccount` URLs)
        add(.get, "/accounts/oidc/{provider_id}/login/", [.anonymous]) { api, req in try await api.socialLoginConfirmPage(req) }
        add(.post, "/accounts/oidc/{provider_id}/login/", [.anonymous]) { api, req in try await api.socialLoginStart(req) }
        add(.get, "/accounts/oidc/{provider_id}/login/callback/", [.anonymous]) { api, req in try await api.socialCallback(req) }
        add(.get, "/accounts/3rdparty/signup/", [.anonymous]) { api, req in try await api.socialSignupPage(req) }
        add(.post, "/accounts/3rdparty/signup/", [.anonymous, .csrfExempt]) { api, req in try await api.socialSignup(req) }
        add(.get, "/accounts/3rdparty/login/cancelled/", [.anonymous]) { api, req in try await api.socialLoginCancelledPage(req) }
        add(.get, "/accounts/3rdparty/login/error/", [.anonymous]) { api, req in try await api.socialLoginErrorPage(req) }

        // Users and groups
        add(.get, "/api/users/") { api, req in try await api.listUsers(req) }
        add(.post, "/api/users/") { api, req in try await api.createUser(req) }
        add(.get, "/api/users/{id}/") { api, req in try await api.getUser(req) }
        add(.put, "/api/users/{id}/") { api, req in try await api.updateUser(req, partial: false) }
        add(.patch, "/api/users/{id}/") { api, req in try await api.updateUser(req, partial: true) }
        add(.delete, "/api/users/{id}/") { api, req in try await api.deleteUser(req) }
        add(.get, "/api/groups/") { api, req in try await api.listGroups(req) }
        add(.post, "/api/groups/") { api, req in try await api.createGroup(req) }
        add(.get, "/api/groups/{id}/") { api, req in try await api.getGroup(req) }
        add(.put, "/api/groups/{id}/") { api, req in try await api.updateGroup(req) }
        add(.patch, "/api/groups/{id}/") { api, req in try await api.updateGroup(req) }
        add(.delete, "/api/groups/{id}/") { api, req in try await api.deleteGroup(req) }

        // Tags, correspondents, document types, storage paths
        func matching<M: APIMatchingObject>(_ type: M.Type) {
            let base = "/api/\(M.endpoint)/"
            add(.get, base) { api, req in try await api.listObjects(M.self, req) }
            add(.post, base) { api, req in try await api.createObject(M.self, req) }
            add(.get, base + "{id}/") { api, req in try await api.getObject(M.self, req) }
            add(.put, base + "{id}/") { api, req in try await api.updateObject(M.self, req, partial: false) }
            add(.patch, base + "{id}/") { api, req in try await api.updateObject(M.self, req, partial: true) }
            add(.delete, base + "{id}/") { api, req in try await api.deleteObject(M.self, req) }
        }
        add(.post, "/api/storage_paths/test/") { api, req in try await api.testStoragePath(req) }
        matching(Tag.self)
        matching(Correspondent.self)
        matching(DocumentType.self)
        matching(StoragePath.self)
        add(.post, "/api/bulk_edit_objects/") { api, req in try await api.bulkEditObjects(req) }

        // Custom fields and saved views
        add(.get, "/api/custom_fields/") { api, req in try await api.listCustomFields(req) }
        add(.post, "/api/custom_fields/") { api, req in try await api.createCustomField(req) }
        add(.get, "/api/custom_fields/{id}/") { api, req in try await api.getCustomField(req) }
        add(.put, "/api/custom_fields/{id}/") { api, req in try await api.updateCustomField(req, partial: false) }
        add(.patch, "/api/custom_fields/{id}/") { api, req in try await api.updateCustomField(req, partial: true) }
        add(.delete, "/api/custom_fields/{id}/") { api, req in try await api.deleteCustomField(req) }
        add(.get, "/api/saved_views/") { api, req in try await api.listSavedViews(req) }
        add(.post, "/api/saved_views/") { api, req in try await api.createSavedView(req) }
        add(.get, "/api/saved_views/{id}/") { api, req in try await api.getSavedView(req) }
        add(.put, "/api/saved_views/{id}/") { api, req in try await api.updateSavedView(req, partial: false) }
        add(.patch, "/api/saved_views/{id}/") { api, req in try await api.updateSavedView(req, partial: true) }
        add(.delete, "/api/saved_views/{id}/") { api, req in try await api.deleteSavedView(req) }

        // Documents
        add(.get, "/api/documents/") { api, req in try await api.listDocuments(req) }
        add(.post, "/api/documents/post_document/", [.streamingBody]) { api, req in try await api.postDocument(req) }
        add(.post, "/api/documents/post_url/") { api, req in try await api.postURL(req) }
        add(.post, "/api/documents/bulk_edit/") { api, req in try await api.bulkEdit(req) }
        add(.post, "/api/documents/delete/") { api, req in try await api.documentOperation(req, method: "delete") }
        add(.post, "/api/documents/reprocess/") { api, req in try await api.documentOperation(req, method: "reprocess") }
        add(.post, "/api/documents/rotate/") { api, req in try await api.rotateDocuments(req) }
        add(.post, "/api/documents/merge/") { api, req in try await api.mergeDocuments(req) }
        add(.post, "/api/documents/merge_as_versions/") { api, req in try await api.mergeAsVersions(req) }
        add(.post, "/api/documents/edit_pdf/") { api, req in try await api.editPDFDocuments(req) }
        add(.post, "/api/documents/remove_password/") { api, req in try await api.removePasswordDocuments(req) }
        add(.post, "/api/documents/bulk_download/") { api, req in try await api.bulkDownload(req) }
        add(.post, "/api/documents/email/") { api, req in try await api.emailDocuments(req) }
        add(.post, "/api/documents/{id}/email/") { api, req in try await api.emailDocuments(req) }
        add(.post, "/api/documents/chat/") { api, req in try await api.documentChat(req) }
        add(.get, "/api/documents/next_asn/") { api, req in try await api.nextASN(req) }
        add(.post, "/api/documents/selection_data/") { api, req in try await api.selectionData(req) }
        add(.get, "/api/documents/{id}/") { api, req in try await api.getDocument(req) }
        add(.put, "/api/documents/{id}/") { api, req in try await api.updateDocument(req, partial: false) }
        add(.patch, "/api/documents/{id}/") { api, req in try await api.updateDocument(req, partial: true) }
        add(.delete, "/api/documents/{id}/") { api, req in try await api.deleteDocument(req) }
        add(.get, "/api/documents/{id}/download/") { api, req in try await api.documentFile(req, disposition: "attachment") }
        add(.get, "/api/documents/{id}/preview/") { api, req in try await api.documentFile(req, disposition: "inline") }
        add(.get, "/api/documents/{id}/thumb/") { api, req in try await api.documentThumbnail(req) }
        add(.get, "/api/documents/{id}/metadata/") { api, req in try await api.documentMetadata(req) }
        add(.get, "/api/documents/{id}/suggestions/") { api, req in try await api.documentSuggestions(req) }
        add(.get, "/api/documents/{id}/history/") { api, req in try await api.documentHistory(req) }
        add(.get, "/api/documents/{id}/share_links/") { api, req in try await api.documentShareLinks(req) }
        add(.get, "/api/documents/{id}/root/") { api, req in try await api.documentRoot(req) }
        add(.get, "/api/documents/{id}/ai_suggestions/") { api, req in try await api.aiSuggestions(req) }
        add(.get, "/api/documents/{id}/similar/") { api, req in try await api.similarDocuments(req) }
        add(.post, "/api/documents/{id}/update_version/", [.streamingBody]) { api, req in try await api.updateVersion(req) }
        add(.patch, "/api/documents/{id}/versions/{version_id}/") { api, req in try await api.updateVersionLabel(req) }
        add(.delete, "/api/documents/{id}/versions/{version_id}/") { api, req in try await api.deleteVersion(req) }
        add(.get, "/api/documents/{id}/notes/") { api, req in try await api.getNotes(req) }
        add(.post, "/api/documents/{id}/notes/") { api, req in try await api.addNote(req) }
        add(.delete, "/api/documents/{id}/notes/") { api, req in try await api.deleteNote(req) }
        add(.get, "/api/trash/") { api, req in try await api.listTrash(req) }
        add(.post, "/api/trash/") { api, req in try await api.trashAction(req) }

        // Share links
        add(.get, "/api/share_links/") { api, req in try await api.listShareLinks(req) }
        add(.post, "/api/share_links/") { api, req in try await api.createShareLink(req) }
        add(.get, "/api/share_links/{id}/") { api, req in try await api.getShareLink(req) }
        add(.delete, "/api/share_links/{id}/") { api, req in try await api.deleteShareLink(req) }
        add(.get, "/share/{slug}/", [.anonymous]) { api, req in try await api.serveShareLink(req) }

        // Share link bundles
        add(.get, "/api/share_link_bundles/") { api, req in try await api.listShareLinkBundles(req) }
        add(.post, "/api/share_link_bundles/") { api, req in try await api.createShareLinkBundle(req) }
        add(.get, "/api/share_link_bundles/{id}/") { api, req in try await api.getShareLinkBundle(req) }
        add(.delete, "/api/share_link_bundles/{id}/") { api, req in try await api.deleteShareLinkBundle(req) }
        add(.post, "/api/share_link_bundles/{id}/rebuild/") { api, req in try await api.rebuildShareLinkBundle(req) }

        // Tasks
        add(.get, "/api/tasks/") { api, req in try await api.listTasks(req) }
        add(.post, "/api/tasks/acknowledge/") { api, req in try await api.acknowledgeTasks(req) }
        add(.get, "/api/tasks/summary/") { api, req in try await api.taskSummary(req) }
        add(.get, "/api/tasks/status_counts/") { api, req in try await api.taskStatusCounts(req) }
        add(.get, "/api/tasks/active/") { api, req in try await api.activeTasks(req) }
        add(.post, "/api/tasks/run/") { api, req in try await api.runTask(req) }
        add(.get, "/api/tasks/{id}/") { api, req in try await api.getTask(req) }

        // Search, statistics, status, configuration, logs
        add(.get, "/api/search/") { api, req in try await api.globalSearch(req) }
        add(.get, "/api/search/autocomplete/") { api, req in try await api.autocomplete(req) }
        add(.get, "/api/statistics/") { api, req in try await api.statistics(req) }
        add(.get, "/api/status/") { api, req in try await api.systemStatus(req) }
        add(.get, "/api/remote_version/") { api, req in try await api.remoteVersion(req) }
        add(.get, "/api/config/") { api, req in try await api.listConfig(req) }
        add(.get, "/api/config/{id}/") { api, req in try await api.getConfig(req) }
        add(.put, "/api/config/{id}/") { api, req in try await api.updateConfig(req) }
        add(.patch, "/api/config/{id}/") { api, req in try await api.updateConfig(req) }
        add(.get, "/api/logs/") { api, req in try await api.listLogs(req) }
        add(.get, "/api/logs/{name}/") { api, req in try await api.getLog(req) }

        // Mail
        add(.get, "/api/mail_accounts/") { api, req in try await api.listMailAccounts(req) }
        add(.post, "/api/mail_accounts/") { api, req in try await api.createMailAccount(req) }
        add(.post, "/api/mail_accounts/test/") { api, req in try await api.testMailAccount(req) }
        add(.get, "/api/mail_accounts/{id}/") { api, req in try await api.getMailAccount(req) }
        add(.put, "/api/mail_accounts/{id}/") { api, req in try await api.updateMailAccount(req, partial: false) }
        add(.patch, "/api/mail_accounts/{id}/") { api, req in try await api.updateMailAccount(req, partial: true) }
        add(.delete, "/api/mail_accounts/{id}/") { api, req in try await api.deleteMailAccount(req) }
        add(.post, "/api/mail_accounts/{id}/process/") { api, req in try await api.processMailAccount(req) }
        add(.get, "/api/mail_rules/") { api, req in try await api.listMailRules(req) }
        add(.post, "/api/mail_rules/") { api, req in try await api.createMailRule(req) }
        add(.get, "/api/mail_rules/{id}/") { api, req in try await api.getMailRule(req) }
        add(.put, "/api/mail_rules/{id}/") { api, req in try await api.updateMailRule(req, partial: false) }
        add(.patch, "/api/mail_rules/{id}/") { api, req in try await api.updateMailRule(req, partial: true) }
        add(.delete, "/api/mail_rules/{id}/") { api, req in try await api.deleteMailRule(req) }
        add(.get, "/api/processed_mail/") { api, req in try await api.listProcessedMail(req) }
        add(.post, "/api/processed_mail/bulk_delete/") { api, req in try await api.bulkDeleteProcessedMail(req) }
        add(.get, "/api/processed_mail/{id}/") { api, req in try await api.getProcessedMail(req) }
        add(.get, "/api/oauth/callback/") { api, req in try await api.mailOAuthCallback(req) }

        // Workflows
        add(.get, "/api/workflows/") { api, req in try await api.listWorkflows(req) }
        add(.post, "/api/workflows/") { api, req in try await api.createWorkflow(req) }
        add(.get, "/api/workflows/{id}/") { api, req in try await api.getWorkflow(req) }
        add(.put, "/api/workflows/{id}/") { api, req in try await api.updateWorkflow(req, partial: false) }
        add(.patch, "/api/workflows/{id}/") { api, req in try await api.updateWorkflow(req, partial: true) }
        add(.delete, "/api/workflows/{id}/") { api, req in try await api.deleteWorkflow(req) }
        for (endpoint, triggers) in [("workflow_triggers", true), ("workflow_actions", false)] {
            add(.get, "/api/\(endpoint)/") { api, req in try await api.listWorkflowParts(req, triggers: triggers) }
            add(.get, "/api/\(endpoint)/{id}/") { api, req in try await api.getWorkflowPart(req, triggers: triggers) }
            add(.put, "/api/\(endpoint)/{id}/") { api, req in try await api.updateWorkflowPart(req, triggers: triggers) }
            add(.patch, "/api/\(endpoint)/{id}/") { api, req in try await api.updateWorkflowPart(req, triggers: triggers) }
            add(.delete, "/api/\(endpoint)/{id}/") { api, req in try await api.deleteWorkflowPart(req, triggers: triggers) }
        }
        return routes
    }

    /// DRF `DefaultRouter` API root.
    func apiIndex(_ request: APIRequest) async throws -> Response {
        let names = ["correspondents", "document_types", "documents", "logs", "tags", "saved_views", "storage_paths", "tasks",
                     "users", "groups", "mail_accounts", "mail_rules", "share_link_bundles", "share_links", "workflow_triggers",
                     "workflow_actions", "workflows", "custom_fields", "config", "processed_mail"]
        var object = JSONObject()
        for name in names {
            object[name] = .string(absoluteURL(request.withPath("/api/\(name)/"), query: QueryItems(nil)))
        }
        return .json(.object(object))
    }
}

extension APIRequest {
    /// The same request with another path (absolute URL building).
    func withPath(_ newPath: String) -> APIRequest {
        APIRequest(head: head, rawBody: rawBody, context: context, path: newPath, params: params, query: query,
                   auth: auth, version: version, body: body)
    }
}
