import Foundation
import HTTPTypes
import Hummingbird

/// An error that becomes an HTTP response, shaped like Django REST framework's
/// (`{"detail": "..."}` or `{"field": ["message"]}`), or a plain-text Django response.
struct APIError: Error, CustomStringConvertible {
    enum Body: Sendable {
        case json(JSON)
        case text(String)
    }

    var status: HTTPResponse.Status
    var body: Body
    var headers: HTTPFields = [:]

    var description: String {
        switch body {
        case .json(let json): "\(status.code) \(json.serialized())"
        case .text(let text): "\(status.code) \(text)"
        }
    }

    static func detail(_ status: HTTPResponse.Status, _ message: String) -> APIError {
        APIError(status: status, body: .json(["detail": .string(message)]))
    }

    /// 400 with an arbitrary DRF error structure.
    static func validation(_ errors: JSON) -> APIError {
        APIError(status: .badRequest, body: .json(errors))
    }

    /// 400 `{"field": ["message"]}`.
    static func field(_ name: String, _ message: String) -> APIError {
        validation(.object(JSONObject([(name, .array([.string(message)]))])))
    }

    /// 400 `{"non_field_errors": ["message"]}`, as a serializer-level `ValidationError`.
    static func nonField(_ message: String) -> APIError {
        field("non_field_errors", message)
    }

    static var notAuthenticated: APIError {
        detail(.unauthorized, "Authentication credentials were not provided.")
    }

    static var permissionDenied: APIError {
        detail(.forbidden, "You do not have permission to perform this action.")
    }

    /// DRF `PermissionDenied(_("Insufficient permissions."))`.
    static var insufficientPermissions: APIError {
        detail(.forbidden, "Insufficient permissions.")
    }

    static func notFound(_ model: String? = nil) -> APIError {
        detail(.notFound, model.map { "No \($0) matches the given query." } ?? "Not found.")
    }

    /// Django `HttpResponseForbidden("...")`: plain text body.
    static func forbiddenText(_ message: String = "Insufficient permissions") -> APIError {
        APIError(status: .forbidden, body: .text(message))
    }

    /// Django `HttpResponseBadRequest("...")`: plain text body.
    static func badRequestText(_ message: String) -> APIError {
        APIError(status: .badRequest, body: .text(message))
    }

    static func methodNotAllowed(_ method: HTTPRequest.Method) -> APIError {
        detail(.methodNotAllowed, "Method \"\(method.rawValue)\" not allowed.")
    }

    static var requiredField: String { "This field is required." }

    static func invalidPK(_ value: String) -> String {
        "Invalid pk \"\(value)\" - object does not exist."
    }
}
