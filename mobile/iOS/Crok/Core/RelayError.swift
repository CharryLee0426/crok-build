import Foundation

/// Every error the relay throws is `ConvexError<{ code, message }>` (relay/convex/lib/auth.ts); the app adds a few of
/// its own for the network and for responses it cannot read.
struct RelayError: Error, Equatable, Sendable, LocalizedError {
    enum Code: String, Sendable, Equatable {
        case unauthenticated = "UNAUTHENTICATED"
        case revoked = "REVOKED"
        case forbidden = "FORBIDDEN"
        case notFound = "NOT_FOUND"
        case offline = "OFFLINE"
        case invalid = "INVALID"
        case expired = "EXPIRED"
        case notConfigured = "NOT_CONFIGURED"
        /// No connection to the relay (URLSession failed, or no network).
        case network = "NETWORK"
        /// The relay failed without a ConvexError (a bug or an outage on the server).
        case server = "SERVER"
        /// The response did not have the expected shape.
        case decoding = "DECODING"
    }

    var code: Code
    var message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    var errorDescription: String? { message }

    /// The device was signed out somewhere else: wipe local credentials and go back to the welcome screen.
    var isRevoked: Bool { code == .revoked }

    private struct Payload: Decodable {
        var code: String?
        var message: String?
    }

    /// Reads the JSON `data` of a ConvexError (`{"code":"OFFLINE","message":"…"}`).
    static func fromConvexData(_ json: String) -> RelayError {
        if let data = json.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return RelayError(
                Code(rawValue: payload.code ?? "") ?? .server,
                payload.message ?? String(localized: "Something went wrong on the relay."))
        }
        // A ConvexError whose data is a plain string.
        if let data = json.data(using: .utf8), let text = try? JSONDecoder().decode(String.self, from: data) {
            return RelayError(.server, text)
        }
        return RelayError(.server, json)
    }

    /// Strips the request id and stack trace Convex adds to server error messages.
    static func cleanServerMessage(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: #"^\[Request ID: [^\]]+\] "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if let firstLine = text.split(separator: "\n").first { text = String(firstLine) }
        text = text.replacingOccurrences(of: "Server Error", with: "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? String(localized: "Something went wrong on the relay.") : text
    }

    static func network(_ error: Error) -> RelayError {
        RelayError(.network, String(localized: "Can't reach the relay. Check your connection."))
    }
}

extension Error {
    /// The relay's error code when this is a RelayError.
    var relayCode: RelayError.Code? { (self as? RelayError)?.code }
}

/// A JSON value for function arguments sent over the HTTP API.
enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        }
    }
}

/// Convex's HTTP API (`POST <deployment>/api/mutation` and `/api/query`). The device sign-in functions are called
/// this way, outside the WebSocket client, so a token refresh never re-enters the client from its own auth callback.
struct ConvexHTTPClient: Sendable {
    var deploymentURL: URL
    var session: URLSession = .shared

    private struct Body: Encodable {
        var path: String
        var args: [String: JSONValue]
        var format = "json"
    }

    func mutation<T: Decodable & Sendable>(_ path: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        try await call(endpoint: "api/mutation", path: path, args: args)
    }

    func query<T: Decodable & Sendable>(_ path: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        try await call(endpoint: "api/query", path: path, args: args)
    }

    private func call<T: Decodable & Sendable>(endpoint: String, path: String, args: [String: JSONValue])
        async throws -> T
    {
        var request = URLRequest(url: deploymentURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppInfo.convexClientHeader, forHTTPHeaderField: "Convex-Client")
        request.httpBody = try JSONEncoder().encode(Body(path: path, args: args))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try ConvexHTTPResponse.decode(T.self, from: data, httpStatus: status)
    }
}

/// Decodes the HTTP API's envelope: `{"status":"success","value":…}` or
/// `{"status":"error","errorMessage":"…","errorData":{code,message}}`.
enum ConvexHTTPResponse {
    private struct Envelope<T: Decodable>: Decodable {
        var status: String
        var value: T?
        var errorMessage: String?
        var errorData: ErrorData?
    }

    private struct ErrorData: Decodable {
        var code: String?
        var message: String?
    }

    private struct StatusOnly: Decodable {
        var status: String
        var errorMessage: String?
        var errorData: ErrorData?
    }

    /// What Convex answers before running any function (bad header, unknown path…): `{"code":…,"message":…}`.
    private struct RequestError: Decodable {
        var code: String
        var message: String
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, httpStatus: Int) throws -> T {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(StatusOnly.self, from: data) else {
            if let rejected = try? decoder.decode(RequestError.self, from: data) {
                throw RelayError(.server, "\(rejected.code): \(rejected.message)")
            }
            if httpStatus == 404 {
                throw RelayError(.notConfigured, String(localized: "That server is not a Crok relay."))
            }
            throw RelayError(.decoding, String(localized: "The relay sent a response Crok can't read."))
        }
        if head.status != "success" {
            if let errorData = head.errorData {
                let code = RelayError.Code(rawValue: errorData.code ?? "") ?? .server
                let message = errorData.message ?? RelayError.cleanServerMessage(head.errorMessage ?? "")
                throw RelayError(code, message)
            }
            throw RelayError(.server, RelayError.cleanServerMessage(head.errorMessage ?? ""))
        }
        if T.self == Nothing.self, let nothing = Nothing() as? T { return nothing }
        do {
            let envelope = try decoder.decode(Envelope<T>.self, from: data)
            guard let value = envelope.value else {
                throw RelayError(.decoding, String(localized: "The relay sent a response Crok can't read."))
            }
            return value
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError(.decoding, String(localized: "The relay sent a response Crok can't read."))
        }
    }
}
