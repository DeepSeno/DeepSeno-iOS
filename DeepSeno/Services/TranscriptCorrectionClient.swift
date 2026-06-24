import Foundation

/// Calls the desktop's POST /api/transcript/correct endpoint and streams
/// back word-by-word corrected text. The endpoint speaks SSE with the same
/// `data: {"type":"chunk","text":"..."}` envelope as /api/query-stream so
/// the consumption pattern matches SSEClient.swift, but it returns no sources.
actor TranscriptCorrectionClient {
    struct Request: Encodable {
        let segmentId: String
        let text: String
        let locale: String
        let context: [String]
    }

    enum CorrectionError: Error {
        case invalidURL
        case invalidResponse(Int)
        case serverError(String)
    }

    func stream(
        host: String,
        port: Int,
        token: String,
        secure: Bool = false,
        fingerprint: String? = nil,
        request: Request,
        onChunk: @Sendable @escaping (String) -> Void
    ) async throws {
        guard let url = URL(string: "\(secure ? "https" : "http")://\(host):\(port)/api/transcript/correct") else {
            throw CorrectionError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        req.timeoutInterval = 30

        let session: URLSession
        if secure, let fingerprint {
            session = URLSession(configuration: .default, delegate: PinningDelegate(fingerprint: fingerprint), delegateQueue: nil)
        } else {
            session = URLSession.shared
        }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CorrectionError.invalidResponse(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw CorrectionError.invalidResponse(http.statusCode)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            switch type {
            case "chunk":
                if let text = json["text"] as? String { onChunk(text) }
            case "done":
                return
            case "error":
                throw CorrectionError.serverError(json["error"] as? String ?? "unknown")
            default:
                break
            }
        }
    }
}
