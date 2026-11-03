import Foundation

struct ToolSpec {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct LLMRequest {
    var system: String
    var messages: [ChatMessage]
    var tools: [ToolSpec]
    /// Claude Code CLI keeps its own history; this resumes it.
    var sessionID: String?
}

struct LLMReply {
    var parts: [MessagePart]
    var raw: JSONValue?
    var model: String?
    var stopReason: String?
    var sessionID: String?
    var notice: String?
    /// Total tokens used by this request, when the provider reports it.
    var tokens: Int?
}

protocol LLMProvider {
    var kind: ProviderKind { get }
    var modelName: String { get }
    func complete(_ request: LLMRequest) async throws -> LLMReply
    /// Streams visible text as it is generated (default: no streaming).
    func completeStreaming(_ request: LLMRequest, onPartial: @escaping (String) -> Void) async throws -> LLMReply
}

extension LLMProvider {
    func completeStreaming(_ request: LLMRequest, onPartial: @escaping (String) -> Void) async throws -> LLMReply {
        try await complete(request)
    }
}

extension Notification.Name {
    /// Status updates (e.g. rate-limit retries) shown while JARVIS is thinking.
    static let jarvisStatus = Notification.Name("jarvis.status")
}

enum LLMError: LocalizedError {
    case missingAPIKey(ProviderKind)
    case http(status: Int, message: String)
    case emptyResponse(String)
    case refused(String)
    case invalidResponse(String)
    case unavailable(String)

    /// Rate limits, exhausted quotas and overload – worth trying another model or brain.
    var isRateLimit: Bool {
        guard case .http(let status, let message) = self else { return false }
        let lower = message.lowercased()
        return status == 429 || status == 529 || lower.contains("quota") || lower.contains("resource_exhausted")
            || lower.contains("rate limit") || lower.contains("overloaded")
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Add your \(provider.shortName) API key in Settings first."
        case .http(let status, let message):
            return "The AI service returned an error (\(status)): \(message)"
        case .emptyResponse(let reason):
            return "The model returned no answer (\(reason))."
        case .refused(let reason):
            return "The model declined this request. \(reason)"
        case .invalidResponse(let detail):
            return "Unexpected response from the AI service: \(detail)"
        case .unavailable(let detail):
            return detail
        }
    }
}

/// Shared HTTP plumbing for the provider clients.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Short timeouts, no waiting for connectivity (server discovery, model lists).
    static let quickSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest, errorParser: (JSONValue) -> String?) async throws -> JSONValue {
        var lastError: Error?
        let attempts = 4
        // Retry transient failures (rate limit / overload / 5xx), honouring the server's suggested delay.
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let json = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
                if (200..<300).contains(status) { return json }
                let message = errorParser(json) ?? String(decoding: data.prefix(500), as: UTF8.self)
                let error = LLMError.http(status: status, message: message)
                if [429, 500, 502, 503, 504, 529].contains(status), attempt < attempts - 1 {
                    let wait = retryDelay(http, json: json) ?? pow(2.0, Double(attempt + 1))
                    // A long suggested wait means the quota is spent – fail fast so a fallback can take over.
                    if wait > 40 { throw error }
                    lastError = error
                    NotificationCenter.default.post(name: .jarvisStatus, object: nil, userInfo: [
                        "text": status == 429 ? "Rate-limited – retrying in \(Int(wait.rounded(.up)))s…" : "Server busy – retrying in \(Int(wait.rounded(.up)))s…"
                    ])
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw error
            } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
                lastError = error
                if attempt == attempts - 1 { break }
            }
        }
        throw lastError ?? LLMError.invalidResponse("request failed")
    }

    /// Seconds the server asked us to wait (Retry-After header or Gemini's RetryInfo).
    static func retryDelay(_ response: HTTPURLResponse?, json: JSONValue) -> Double? {
        if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        for detail in json["error"]?["details"]?.arrayValue ?? [] {
            if let delay = detail["retryDelay"]?.stringValue,
               let seconds = Double(delay.replacingOccurrences(of: "s", with: "")) {
                return seconds
            }
        }
        return nil
    }

    static func jsonRequest(url: URL, method: String = "POST", headers: [String: String], body: JSONValue?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = body.encodedData() }
        return request
    }
}
