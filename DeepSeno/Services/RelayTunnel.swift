import Foundation

/// Phone-side WebSocket tunnel (relay or LAN). Mirrors Android RelayTunnel.kt.
class RelayTunnel: @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private var url: String = ""
    private var machineId: String = ""
    private var authToken: String?
    private var intentionallyClosed = false
    private var wsConnected = false

    private var pendingRequests: [String: CheckedContinuation<RelayProxyResponse, Never>] = [:]

    struct RelayProxyResponse { let status: Int; let frames: [Data]; let error: String? }

    func start(url: String, machineId: String = "", authToken: String? = nil) {
        self.url = url; self.machineId = machineId; self.authToken = authToken
        self.intentionallyClosed = false; self.wsConnected = false
        connect()
        startHeartbeat()
    }

    func stop() {
        intentionallyClosed = true
        stopHeartbeat()
        wsConnected = false
        for (_, cont) in pendingRequests { cont.resume(returning: RelayProxyResponse(status: 0, frames: [], error: "tunnel stopped")) }
        pendingRequests.removeAll()
        task?.cancel(with: .goingAway, reason: nil); task = nil
    }

    // MARK: - Heartbeat
    private var heartbeatTimer: Timer?
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }
    private func stopHeartbeat() { heartbeatTimer?.invalidate(); heartbeatTimer = nil }

    func sendProxyRequest(frames: [Data]) async -> RelayProxyResponse {
        if !wsConnected {
            _ = await withTaskGroup(of: Bool.self) { group in
                group.addTask { while !self.wsConnected && !self.intentionallyClosed { try? await Task.sleep(for: .milliseconds(100)) }; return self.wsConnected }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
                return await group.next() ?? false
            }
        }
        guard wsConnected, !intentionallyClosed else {
            return RelayProxyResponse(status: 0, frames: [], error: "WS connect timeout")
        }
        let id = UUID().uuidString
        let frameB64 = frames.map { $0.base64EncodedString() }
        let payload: [String: Any] = ["type": "proxy-req", "id": id, "frames": frameB64]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: jsonData, encoding: .utf8) else {
            return RelayProxyResponse(status: 0, frames: [], error: "encode failed")
        }
        task?.send(.string(text)) { _ in }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                pendingRequests[id] = cont
                Task {
                    try? await Task.sleep(for: .seconds(45))
                    if let c = pendingRequests.removeValue(forKey: id) {
                        c.resume(returning: RelayProxyResponse(status: 0, frames: [], error: "proxy timeout"))
                    }
                }
            }
        } onCancel: {
            if let c = pendingRequests.removeValue(forKey: id) {
                c.resume(returning: RelayProxyResponse(status: 0, frames: [], error: "cancelled"))
            }
        }
    }

    private func connect() {
        guard let wsURL = URL(string: url) else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        if !machineId.isEmpty {
            var req = URLRequest(url: wsURL, timeoutInterval: 120)
            req.setValue(machineId, forHTTPHeaderField: "X-Machine-Id")
            task = session.webSocketTask(with: req)
        } else {
            task = session.webSocketTask(with: URLRequest(url: wsURL, timeoutInterval: 120))
        }
        task?.maximumMessageSize = 0; task?.resume()

        if let token = authToken {
            let auth: [String: Any] = ["type": "auth", "token": token]
            if let d = try? JSONSerialization.data(withJSONObject: auth),
               let s = String(data: d, encoding: .utf8) {
                task?.send(.string(s)) { _ in }
            }
        }
        receiveLoop()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task {
                switch result {
                case .success(let message):
                    let text: String?
                    switch message { case .string(let s): text = s; case .data(let d): text = String(data: d, encoding: .utf8); @unknown default: text = nil }
                    if let text { self.handleMessage(text) }
                    await self.receiveLoop()
                case .failure:
                    self.wsConnected = false
                    for (_, cont) in self.pendingRequests { cont.resume(returning: RelayProxyResponse(status: 0, frames: [], error: "WS disconnected")) }
                    self.pendingRequests.removeAll()
                    if !self.intentionallyClosed {
                        try? await Task.sleep(for: .seconds(5))
                        if !self.intentionallyClosed { self.connect() }
                    }
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "connected", "ws-id": wsConnected = true
        case "proxy-resp":
            guard let id = json["id"] as? String,
                  let cont = pendingRequests.removeValue(forKey: id) else { return }
            if let error = json["error"] as? String { cont.resume(returning: RelayProxyResponse(status: 0, frames: [], error: error)) }
            else {
                let s = json["status"] as? Int ?? 200
                let f: [Data] = (json["frames"] as? [String])?.compactMap { Data(base64Encoded: $0) } ?? []
                cont.resume(returning: RelayProxyResponse(status: s, frames: f, error: nil))
            }
        default: break
        }
    }
}
