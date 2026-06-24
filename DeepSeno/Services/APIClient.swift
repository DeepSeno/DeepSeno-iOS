import Foundation

actor APIClient {

    // MARK: - Configuration

    let host: String
    let port: Int
    let token: String
    let secure: Bool

    // Direct HTTP mode
    private let session: URLSession
    private let decoder: JSONDecoder
    private let pinningDelegate: PinningDelegate?

    // Relay/LAN WS proxy mode
    private var relayMode = false
    private var relayAesKey: Data?
    private var relayTunnel: RelayTunnel?

    init(host: String, port: Int, token: String, secure: Bool = false, fingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.secure = secure
        self.decoder = JSONDecoder()
        if secure, let fingerprint {
            let delegate = PinningDelegate(fingerprint: fingerprint)
            self.pinningDelegate = delegate
            self.session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        } else {
            self.pinningDelegate = nil
            self.session = URLSession.shared
        }
    }

    /// Configure relay mode — all API calls go through the WebSocket tunnel.
    func configureRelay(tunnel: RelayTunnel, aesKey: Data) {
        self.relayMode = true
        self.relayTunnel = tunnel
        self.relayAesKey = aesKey
    }

    /// Configure LAN WebSocket proxy mode (same as relay but with LAN-derived key).
    func configureLan(tunnel: RelayTunnel, aesKey: Data) {
        self.relayMode = true
        self.relayTunnel = tunnel
        self.relayAesKey = aesKey
    }

    // MARK: - Request dispatcher

    private var baseURL: String { "\(secure ? "https" : "http")://\(host):\(port)" }

    /// If in relay mode, encrypt the request and send through the WebSocket.
    /// Otherwise, send a direct HTTP request.
    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> T {
        if relayMode {
            return try await relayRequest(method, path: path, body: body, headers: headers)
        }
        return try await httpRequest(method, path: path, body: body, headers: headers, timeout: timeout)
    }

    /// Fire-and-forget variant — ignores response body.
    private func requestVoid(
        _ method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws {
        if relayMode {
            _ = try await relayRequest(method, path: path, body: body, headers: headers)
            return
        }
        guard let url = URL(string: "\(baseURL)\(path)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        if let body { req.httpBody = body }
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Relay proxy request

    private func relayRequest(
        _ method: String,
        path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> (Int, [String: String], Data?) {
        guard let tunnel = relayTunnel, let aesKey = relayAesKey else {
            throw APIError.relayNotConfigured
        }
        var allHeaders = headers
        allHeaders["Authorization"] = "Bearer \(token)"
        let frames = try RelayCrypto.encryptRequest(
            aesKey: aesKey, method: method, path: path, headers: allHeaders, body: body
        )
        let resp = await tunnel.sendProxyRequest(frames: frames)
        if let error = resp.error { throw APIError.relayError(error) }
        let decrypted = try RelayCrypto.decryptResponse(aesKey: aesKey, frames: resp.frames)
        return (decrypted.status, decrypted.headers, decrypted.body)
    }

    /// Decode relay response body as a generic type.
    private func relayRequest<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        let (status, _, data) = try await relayRequest(method, path: path, body: body, headers: headers)
        guard (200...299).contains(status) else {
            throw APIError.httpError(status)
        }
        guard let data else { throw APIError.invalidResponse }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Direct HTTP request

    private func httpRequest<T: Decodable>(
        _ method: String,
        path: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = timeout
        if let body { req.httpBody = body }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Convenience

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path: path)
    }

    private func post<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        let data = try JSONEncoder().encode(body)
        return try await request("POST", path: path, body: data)
    }

    // MARK: - Discovery

    func ping() async throws -> PingResponse {
        try await get("/api/ping")
    }

    // MARK: - Recordings

    func getRecordings() async throws -> [Recording] {
        try await get("/api/recordings")
    }

    func getCalendarActivity(start: String, end: String) async throws -> [CalendarDayActivity] {
        try await get("/api/briefing/calendar?start=\(start)&end=\(end)")
    }

    func getSegments(recordingId: Int) async throws -> [Segment] {
        try await get("/api/recordings/\(recordingId)/segments")
    }

    func getMeetingNotes(recordingId: Int) async throws -> MeetingNotes {
        try await get("/api/recordings/\(recordingId)/notes")
    }

    func search(query: String) async throws -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return try await get("/api/search?q=\(encoded)")
    }

    // MARK: - Images

    struct ImageInfo: Decodable {
        let count: Int
        let images: [String]
    }

    func getImageInfo(recordingId: Int) async throws -> ImageInfo {
        try await get("/api/recordings/\(recordingId)/images")
    }

    func imageURL(recordingId: Int, index: Int = 0) -> URL? {
        URL(string: "\(baseURL)/api/recordings/\(recordingId)/image/\(index)")
    }

    func fetchImageData(recordingId: Int, index: Int = 0) async throws -> Data {
        guard let url = imageURL(recordingId: recordingId, index: index) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return data
    }

    func mediaURL(recordingId: Int) -> URL? {
        URL(string: "\(baseURL)/api/recordings/\(recordingId)/media?token=\(token)")
    }

    // MARK: - RAG

    func query(question: String) async throws -> QueryResponse {
        try await post("/api/query", body: ["question": question])
    }

    // MARK: - Summaries

    func getDailySummary(date: String) async throws -> DailySummary {
        try await get("/api/daily-summary/\(date)")
    }

    func getWeeklySummary(startDate: String) async throws -> WeeklySummary {
        try await get("/api/weekly-summary/\(startDate)")
    }

    func regenerateBriefing(mode: String, date: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/briefing/regenerate?mode=\(mode)&date=\(date)") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.uploadFailed
        }
        _ = data
    }

    // MARK: - Extracted Items

    func getExtractedItems(type: String? = nil, status: String? = nil, recordingId: Int? = nil) async throws -> [ExtractedItem] {
        var path = "/api/extracted-items"
        var params: [String] = []
        if let type { params.append("type=\(type)") }
        if let status { params.append("status=\(status)") }
        if let recordingId { params.append("recordingId=\(recordingId)") }
        if !params.isEmpty { path += "?" + params.joined(separator: "&") }
        return try await get(path)
    }

    func updateItemStatus(id: Int, status: String) async throws {
        let body = try JSONEncoder().encode(["status": status])
        try await requestVoid("PATCH", path: "/api/extracted-items/\(id)/status", body: body)
    }

    // MARK: - Chat

    func getChatSessions() async throws -> [ChatSession] {
        try await get("/api/chat/sessions")
    }

    func createChatSession(title: String? = nil) async throws -> ChatSession {
        let body: [String: String] = title != nil ? ["title": title!] : [:]
        return try await post("/api/chat/sessions", body: body)
    }

    func getSessionMessages(sessionId: Int) async throws -> [ChatMessage] {
        try await get("/api/chat/sessions/\(sessionId)/messages")
    }

    // MARK: - Notes

    func createNote(content: String) async throws {
        let body = try JSONEncoder().encode(["content": content])
        try await requestVoid("POST", path: "/api/notes", body: body)
    }

    // MARK: - Briefing

    func getBriefing(date: String? = nil) async throws -> Briefing {
        let d = date ?? {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
        }()
        return try await get("/api/briefing?date=\(d)")
    }

    // MARK: - Upload

    func upload(fileURL: URL, fileName: String, bookmarks: String? = nil) async throws -> UploadResponse {
        // If in relay/LAN mode, load file into memory and encrypt through relay
        if relayMode {
            let data = try Data(contentsOf: fileURL)
            let body = data
            let headers = [
                "Content-Type": mimeType(for: fileName),
                "X-Filename": fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName,
            ]
            var h = headers
            if let bookmarks { h["X-Bookmarks"] = bookmarks }
            let (status, _, respData) = try await relayRequest("POST", path: "/api/upload", body: body, headers: h)
            guard (200...299).contains(status) else { throw APIError.uploadFailed }
            guard let data = respData else { throw APIError.invalidResponse }
            return try decoder.decode(UploadResponse.self, from: data)
        }
        guard let url = URL(string: "\(baseURL)/api/upload") else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mimeType(for: fileName), forHTTPHeaderField: "Content-Type")
        let encodedName = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        req.setValue(encodedName, forHTTPHeaderField: "X-Filename")
        if let bookmarks { req.setValue(bookmarks, forHTTPHeaderField: "X-Bookmarks") }
        req.timeoutInterval = 120
        let (data, response) = try await session.upload(for: req, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.uploadFailed
        }
        return try decoder.decode(UploadResponse.self, from: data)
    }

    func uploadImages(fileURLs: [URL], fileNames: [String], groupName: String) async throws -> UploadResponse {
        // Build multipart body
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        for (i, f) in fileURLs.enumerated() {
            let name = i < fileNames.count ? fileNames[i] : f.lastPathComponent
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: image/jpeg\r\n\r\n")
            if let d = try? Data(contentsOf: f) { body.append(d) }
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        if relayMode {
            let headers = [
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
                "X-Group-Name": groupName,
            ]
            let (status, _, respData) = try await relayRequest("POST", path: "/api/upload-multi", body: body, headers: headers)
            guard (200...299).contains(status) else { throw APIError.uploadFailed }
            guard let data = respData else { throw APIError.invalidResponse }
            return try decoder.decode(UploadResponse.self, from: data)
        }
        guard let url = URL(string: "\(baseURL)/api/upload-multi") else { throw APIError.invalidURL }
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("deepseno-upload-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let handle = try FileHandle(forWritingTo: bodyFile)
        defer { try? handle.close() }
        func write(_ s: String) throws { if let d = s.data(using: .utf8) { try handle.write(contentsOf: d) } }
        for (i, f) in fileURLs.enumerated() {
            let name = i < fileNames.count ? fileNames[i] : f.lastPathComponent
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(name)\"\r\nContent-Type: image/jpeg\r\n\r\n")
            let input = try FileHandle(forReadingFrom: f); defer { try? input.close() }
            while true { let c = try input.read(upToCount: 256*1024) ?? Data(); if c.isEmpty { break }; try handle.write(contentsOf: c) }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n"); try handle.close()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(groupName, forHTTPHeaderField: "X-Group-Name")
        req.timeoutInterval = 120
        let (data, response) = try await session.upload(for: req, fromFile: bodyFile)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.uploadFailed
        }
        return try decoder.decode(UploadResponse.self, from: data)
    }

    private func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "txt": return "text/plain"
        case "doc", "docx": return "application/msword"
        default: return "application/octet-stream"
        }
    }
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case uploadFailed
    case relayNotConfigured
    case relayError(String)
    case uploadNotSupportedInRelay

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .invalidResponse: "Invalid response"
        case .httpError(let code): "HTTP error \(code)"
        case .uploadFailed: "Upload failed"
        case .relayNotConfigured: "Relay not configured"
        case .relayError(let msg): "Relay error: \(msg)"
        case .uploadNotSupportedInRelay: "Upload not supported in relay mode"
        }
    }
}
