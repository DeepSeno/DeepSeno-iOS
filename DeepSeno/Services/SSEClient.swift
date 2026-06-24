import Foundation

actor SSEClient {
    func queryStream(
        host: String,
        port: Int,
        token: String,
        secure: Bool = false,
        fingerprint: String? = nil,
        question: String,
        sessionId: Int?,
        onChunk: @Sendable @escaping (String) -> Void,
        onStatus: @Sendable @escaping (String) -> Void
    ) async throws -> [StreamingMessage.Source] {
        guard let url = URL(string: "\(secure ? "https" : "http")://\(host):\(port)/api/query-stream") else {
            throw APIError.invalidURL
        }

        var body: [String: Any] = ["question": question]
        if let sessionId { body["sessionId"] = sessionId }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let session = Self.makeSession(secure: secure, fingerprint: fingerprint)
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }

        var sources: [StreamingMessage.Source] = []

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "chunk":
                if let text = json["text"] as? String {
                    onChunk(text)
                }
            case "status":
                if let status = json["status"] as? String {
                    onStatus(status)
                }
            case "done":
                if let sourcesData = json["sources"],
                   let sourcesJson = try? JSONSerialization.data(withJSONObject: sourcesData),
                   let decoded = try? JSONDecoder().decode(
                       [StreamingMessage.Source].self, from: sourcesJson
                   ) {
                    sources = decoded
                }
            case "error":
                let errorMsg = json["error"] as? String ?? "Unknown error"
                throw SSEError.serverError(errorMsg)
            default:
                break
            }
        }

        return sources
    }

    /// LAN → shared session (plain http). Public relay → a pinned session whose
    /// delegate the session retains; the SSE stream finishes within this call so
    /// the session/delegate stay alive for its lifetime.
    private static func makeSession(secure: Bool, fingerprint: String?) -> URLSession {
        guard secure, let fingerprint else { return URLSession.shared }
        let delegate = PinningDelegate(fingerprint: fingerprint)
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }
}

enum SSEError: Error, LocalizedError {
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let msg): "Server error: \(msg)"
        }
    }
}
