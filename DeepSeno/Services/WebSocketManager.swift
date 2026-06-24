import Foundation

@Observable
class WebSocketManager: @unchecked Sendable {
    var isConnected = false
    var lastEvent: ServerEvent?

    /// 最近一次连接的认证结果,供 ReconnectCoordinator 逐个试连时判定。
    /// connect() 调用时重置为 nil。
    enum AuthOutcome: Sendable { case accepted, rejected }
    var authOutcome: AuthOutcome?

    private var webSocketTask: URLSessionWebSocketTask?
    /// Plain session for ws:// (LAN). Reused across reconnects.
    private let plainSession = URLSession(configuration: .default)
    /// Pinned session for wss:// (public relay). Rebuilt per connect() when a
    /// fingerprint is supplied; nil for LAN. The delegate is retained by the
    /// session, and we keep a strong ref here so it isn't deallocated.
    private var pinnedSession: URLSession?
    private var pinningDelegate: PinningDelegate?
    private var host: String = ""
    private var port: Int = 0
    private var token: String = ""
    private var secure: Bool = false
    private var reconnectDelay: TimeInterval = 1
    private var shouldReconnect = false

    /// Session to use for the current connection target.
    private var activeSession: URLSession { secure ? (pinnedSession ?? plainSession) : plainSession }

    enum ServerEvent: Sendable {
        case connected(serverVersion: String)
        case recordingNew(recording: Recording)
        case recordingStatus(recordingId: Int, status: String, progress: Double?)
        case pipelineProgress(taskId: String, step: String, progress: Double)
        case transcribePartial(text: String)
        case transcribeFinal(text: String)
    }

    func connect(host: String, port: Int, token: String, secure: Bool = false, fingerprint: String? = nil) {
        // Close existing connection first to prevent leak
        closeExisting()
        self.authOutcome = nil
        self.host = host
        self.port = port
        self.token = token
        self.secure = secure
        // Build (or tear down) the pinned session for this target.
        if secure, let fingerprint {
            let delegate = PinningDelegate(fingerprint: fingerprint)
            self.pinningDelegate = delegate
            self.pinnedSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        } else {
            self.pinningDelegate = nil
            self.pinnedSession = nil
        }
        self.shouldReconnect = true
        self.reconnectDelay = 1
        doConnect()
    }

    // MARK: - Send messages

    func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    func sendBinary(_ data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }

    func disconnect() {
        shouldReconnect = false
        closeExisting()
    }

    /// Close existing WebSocket without affecting reconnect flag.
    private func closeExisting() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    private func doConnect() {
        // Cancel previous task without triggering reconnect loop
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        guard let url = URL(string: "\(secure ? "wss" : "ws")://\(host):\(port)") else { return }
        let task = activeSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        // Send auth message
        do {
            let authPayload = try JSONEncoder().encode(["type": "auth", "token": token])
            task.send(.data(authPayload)) { error in
                if let error {
                    print("[WS] Auth send error: \(error)")
                    Task { @MainActor [weak self] in
                        self?.scheduleReconnect()
                    }
                }
            }
        } catch {
            print("[WS] Auth encode error: \(error)")
            scheduleReconnect()
            return
        }

        receiveLoop(task: task)
    }

    private func receiveLoop(task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleMessage(text, task: task)
                    }
                    self.receiveLoop(task: task)
                case .failure(let error):
                    // Don't touch state if this is a stale task (replaced by a new connection)
                    if task !== self.webSocketTask {
                        return
                    }
                    self.isConnected = false
                    // Don't reconnect on intentional disconnect
                    if let urlError = error as? URLError,
                       urlError.code == .cancelled {
                        return
                    }
                    // Don't retry on invalid token (4003)
                    if task.closeCode.rawValue == 4003 {
                        self.authOutcome = .rejected
                        return
                    }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleMessage(_ text: String, task: URLSessionWebSocketTask) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "connected":
            isConnected = true
            authOutcome = .accepted
            reconnectDelay = 1
            let version = json["serverVersion"] as? String ?? ""
            lastEvent = .connected(serverVersion: version)

        case "ping":
            task.send(.string(#"{"type":"pong"}"#)) { _ in }

        case "recording:new":
            if let recData = json["recording"] as? [String: Any],
               let jsonData = try? JSONSerialization.data(withJSONObject: recData),
               let recording = try? JSONDecoder().decode(Recording.self, from: jsonData) {
                lastEvent = .recordingNew(recording: recording)
            }

        case "recording:status":
            if let recordingId = json["recordingId"] as? Int,
               let status = json["status"] as? String {
                let progress = json["progress"] as? Double
                lastEvent = .recordingStatus(
                    recordingId: recordingId,
                    status: status,
                    progress: progress
                )
            }

        case "pipeline:progress":
            if let taskId = json["taskId"] as? String,
               let step = json["step"] as? String,
               let progress = json["progress"] as? Double {
                lastEvent = .pipelineProgress(
                    taskId: taskId,
                    step: step,
                    progress: progress
                )
            }

        case "transcribe:partial":
            if let text = json["text"] as? String {
                lastEvent = .transcribePartial(text: text)
            }

        case "transcribe:final":
            if let text = json["text"] as? String {
                lastEvent = .transcribeFinal(text: text)
            }

        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.shouldReconnect else { return }
            self.doConnect()
        }
    }
}
