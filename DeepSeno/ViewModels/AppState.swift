import SwiftUI
import SwiftData

@Observable
class AppState: @unchecked Sendable {
    // Connection — reflects the ACTIVE target.
    var connectionHost: String?
    var connectionPort: Int?
    var connectionToken: String?
    var connectionSecure: Bool = false
    var connectionFingerprint: String?

    /// Current transport mode (mirrors Android)
    var relayTransportMode: String = "none"  // "none" | "lan" | "relay" | "p2p"

    // State
    var apiClient: APIClient?
    var webSocket = WebSocketManager()
    var captureQueue = CaptureQueue()
    var sseClient = SSEClient()
    var cacheManager = CacheManager()
    let notificationService = NotificationService.shared
    let reconnectCoordinator = ReconnectCoordinator()
    private let pathMonitor = NetworkPathMonitor()
    private var userDisconnected = false

    // Relay
    private let relayServerBase: String = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "RelayServerBaseURL") as? String else {
            return ""
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }()
    private var relayTunnel: RelayTunnel?
    private var relayAesKey: Data?

    weak var activeStreamer: AudioStreamer?

    let captureVM = CaptureViewModel()
    let sourcesVM = SourcesViewModel()
    let chatVM = ChatViewModel()
    let briefingVM = BriefingViewModel()
    let settingsVM = SettingsViewModel()

    var selectedTab: AppTab = .capture
    var pendingChatPrompt: String?

    var isConnected: Bool { webSocket.isConnected || relayTransportMode != "none" }
    var pendingCount: Int { captureQueue.pendingCount }

    // UserDefaults keys
    private let hostKey = "deepseno_host"
    private let portKey = "deepseno_port"
    private let tokenKey = "deepseno_token"
    private let tokenAccount = "deepseno_lan_token"
    private let publicHostKey = "deepseno_public_host"
    private let publicPortKey = "deepseno_public_port"
    private let fingerprintKey = "deepseno_fingerprint"

    // Relay persistence
    private let relayMachineIdKey = "deepseno_relay_mid"
    private let relayDesktopPubKey = "deepseno_relay_desktop_pub"
    private let relayPhonePubKey = "deepseno_relay_phone_pub"
    private let relayAesKeyKey = "deepseno_relay_aes_key"

    init() {
        notificationService.requestAuthorization()
        KeychainStore.migrateTokenIfNeeded(userDefaultsKey: tokenKey, account: tokenAccount)

        let savedPort = UserDefaults.standard.integer(forKey: portKey)
        connectionHost = UserDefaults.standard.string(forKey: hostKey)
        connectionPort = savedPort > 0 ? savedPort : nil
        connectionFingerprint = UserDefaults.standard.string(forKey: fingerprintKey)
        Task { @MainActor in await self.reconnectIfPossible() }
        pathMonitor.onBecameSatisfied = { [weak self] in
            Task { @MainActor in
                guard let self, !self.webSocket.isConnected else { return }
                await self.reconnectIfPossible()
            }
        }
        pathMonitor.start()
    }

    func setModelContext(_ context: ModelContext) {
        captureQueue.setModelContext(context)
        cacheManager.setModelContext(context)
    }

    func connectFromQR(jsonString: String) -> Bool {
        let raw = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let info = ConnectionInfo.fromPairingURL(raw) {
            Task { @MainActor in await connect(info: info) }
            return true
        }

        guard let data = raw.data(using: .utf8),
              let info = try? JSONDecoder().decode(ConnectionInfo.self, from: data) else {
            return false
        }
        Task { @MainActor in await connect(info: info) }
        return true
    }

    /// Connect with full ConnectionInfo. Tries LAN first, falls back to relay.
    @MainActor
    func connect(info: ConnectionInfo) async {
        userDisconnected = false
        let lanProvided = !info.host.isEmpty && info.port > 0

        // Persist LAN info
        if lanProvided {
            UserDefaults.standard.set(info.host, forKey: hostKey)
            UserDefaults.standard.set(info.port, forKey: portKey)
        }
        if let fp = info.fingerprint {
            UserDefaults.standard.set(fp, forKey: fingerprintKey)
        }
        KeychainStore.setToken(info.token, account: tokenAccount)

        // Try LAN first
        if lanProvided {
            let probe = HTTPServerProbe(timeout: 1.5)
            if await probe.isReachable(host: info.host, port: info.port) {
                connectLan(host: info.host, port: info.port, token: info.token)
                return
            }
        }

        // Fall back to relay
        if let relay = info.relay, !relay.mid.isEmpty {
            await connectRelay(relay: relay, token: info.token)
            return
        }

        // No relay — try LAN anyway
        if lanProvided {
            connectLan(host: info.host, port: info.port, token: info.token)
        }
    }

    // MARK: - LAN direct (unified WS proxy protocol, same as relay)

    private func connectLan(host: String, port: Int, token: String) {
        relayTunnel?.stop()
        relayTransportMode = "lan"
        connectionHost = host
        connectionPort = port
        connectionToken = token
        connectionSecure = false
        connectionFingerprint = nil

        let aesKey = RelayCrypto.deriveLanKey(token: token)
        relayAesKey = aesKey

        let tunnel = RelayTunnel()
        tunnel.start(url: "ws://\(host):\(port)", authToken: token)
        relayTunnel = tunnel

        apiClient = APIClient(host: host, port: port, token: token, secure: false)
        Task { await apiClient?.configureLan(tunnel: tunnel, aesKey: aesKey) }

        // Keep WebSocket for push events (audio streaming etc.)
        webSocket.connect(host: host, port: port, token: token, secure: false)

        Task {
            await captureQueue.processQueue(apiClient: apiClient!)
            await cacheManager.syncOnConnect(apiClient: apiClient!)
        }
    }

    // MARK: - Relay (encrypted server relay)

    private func connectRelay(relay: ConnectionInfo.RelayInfo, token: String) async {
        guard !relayServerBase.isEmpty else { return }
        relayTunnel?.stop()
        relayTransportMode = "relay"
        connectionToken = token

        do {
            // Generate ECDH key pair + derive AES key
            let (privKey, phonePubB64) = try RelayCrypto.generateKeyPair()
            let aesKey = try RelayCrypto.deriveSharedKey(
                privateKey: privKey, peerPublicKeyBase64: relay.pub, nonceBase64: relay.nonce
            )
            relayAesKey = aesKey

            // Persist relay info
            UserDefaults.standard.set(relay.mid, forKey: relayMachineIdKey)
            UserDefaults.standard.set(relay.pub, forKey: relayDesktopPubKey)
            UserDefaults.standard.set(phonePubB64, forKey: relayPhonePubKey)
            KeychainStore.setToken(aesKey.base64EncodedString(), account: relayAesKeyKey)

            // POST to /relay/pair
            guard let pairURL = URL(string: "\(relayServerBase)/relay/pair") else {
                relayTransportMode = "none"; return
            }
            var req = URLRequest(url: pairURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(relay.mid, forHTTPHeaderField: "X-Machine-Id")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "machineId": relay.mid, "phonePubKey": phonePubB64, "nonce": relay.nonce,
            ])
            req.timeoutInterval = 10
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 202 else {
                relayTransportMode = "none"; return
            }

            // Create WebSocket tunnel to relay server
            let wsURL = relayServerBase
                .replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
                + "/relay/client-ws?machine_id=\(relay.mid)"
            let tunnel = RelayTunnel()
            tunnel.start(url: wsURL, machineId: relay.mid)
            relayTunnel = tunnel

            // Configure API client for relay
            connectionHost = relayServerBase.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "/api/v1", with: "")
            connectionPort = 443
            connectionSecure = true
            apiClient = APIClient(
                host: connectionHost!, port: 443, token: token, secure: true
            )
            await apiClient?.configureRelay(tunnel: tunnel, aesKey: aesKey)

            // Trigger queue processing + cache sync (same as Android)
            if let api = apiClient {
                await captureQueue.processQueue(apiClient: api)
                await cacheManager.syncOnConnect(apiClient: api)
            }

        } catch {
            relayTransportMode = "none"
        }
    }

    // MARK: - Disconnect / Forget

    func disconnect() {
        userDisconnected = true
        relayTunnel?.stop()
        relayTunnel = nil
        relayAesKey = nil
        relayTransportMode = "none"
        webSocket.disconnect()
        apiClient = nil
        connectionHost = nil
        connectionPort = nil
        connectionToken = nil
        connectionSecure = false
        connectionFingerprint = nil
    }

    func forget() {
        userDisconnected = true
        relayTunnel?.stop()
        relayTunnel = nil
        relayAesKey = nil
        relayTransportMode = "none"
        webSocket.disconnect()
        apiClient = nil
        connectionHost = nil
        connectionPort = nil
        connectionToken = nil
        connectionSecure = false
        connectionFingerprint = nil

        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: portKey)
        UserDefaults.standard.removeObject(forKey: publicHostKey)
        UserDefaults.standard.removeObject(forKey: publicPortKey)
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
        UserDefaults.standard.removeObject(forKey: relayMachineIdKey)
        UserDefaults.standard.removeObject(forKey: relayDesktopPubKey)
        UserDefaults.standard.removeObject(forKey: relayPhonePubKey)
        KeychainStore.setToken(nil, account: tokenAccount)
        KeychainStore.setToken(nil, account: relayAesKeyKey)
    }

    /// Backward-compatible entry.
    func connect(host: String, port: Int, token: String) {
        Task { @MainActor in
            await connect(info: ConnectionInfo(
                host: host, port: port, token: token, fingerprint: connectionFingerprint, relay: nil
            ))
        }
    }

    var hasSavedPairing: Bool { KeychainStore.token(account: tokenAccount) != nil }

    @discardableResult
    func connectWithSavedToken(host: String, port: Int) -> Bool {
        guard let token = KeychainStore.token(account: tokenAccount) else { return false }
        connect(host: host, port: port, token: token)
        return true
    }

    @MainActor
    func reconnectIfPossible() async {
        guard !userDisconnected else { return }
        guard let token = KeychainStore.token(account: tokenAccount) else { return }

        if let host = UserDefaults.standard.string(forKey: hostKey) {
            let port = UserDefaults.standard.integer(forKey: portKey)
            if port > 0 {
                let probe = HTTPServerProbe(timeout: 1.5)
                if await probe.isReachable(host: host, port: port) {
                    connectLan(host: host, port: port, token: token)
                    return
                }
                connectLan(host: host, port: port, token: token)
            }
        }
    }
}

private extension ConnectionInfo {
    static func fromPairingURL(_ raw: String) -> ConnectionInfo? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedPath == "mobile/pair" || normalizedPath.hasSuffix("/mobile/pair") else {
            return nil
        }

        var params = [String: String]()
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name] = value
            }
        }

        guard let token = params["token"], !token.isEmpty else {
            return nil
        }

        let host = params["host"] ?? ""
        let port = Int(params["port"] ?? "") ?? 0
        let fingerprint = (params["fingerprint"]?.isEmpty == false) ? params["fingerprint"] : nil

        let relayMid = params["mid"] ?? params["relay_mid"] ?? params["relayMid"]
        let relayPub = params["pub"] ?? params["relay_pub"] ?? params["relayPub"]
        let relayNonce = params["nonce"] ?? params["relay_nonce"] ?? params["relayNonce"]
        let relay: RelayInfo?
        if let relayMid, let relayPub, let relayNonce,
           !relayMid.isEmpty, !relayPub.isEmpty, !relayNonce.isEmpty {
            relay = RelayInfo(mid: relayMid, pub: relayPub, nonce: relayNonce)
        } else {
            relay = nil
        }

        guard (!host.isEmpty && port > 0) || relay != nil else {
            return nil
        }

        return ConnectionInfo(host: host, port: port, token: token, fingerprint: fingerprint, relay: relay)
    }
}
