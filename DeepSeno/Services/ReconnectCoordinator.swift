import Foundation

enum ConnectionStatus: Sendable {
    case connecting     // 正在试上次的地址
    case searching      // 正在用 Bonjour 查找电脑
    case connected
    case offline        // 找不到电脑(电脑没开/不在同网络)
}

/// 编排自动重连:① 试上次 IP ② 失败则 Bonjour 发现 ③ 逐个候选试连(WS 认证通过者胜出)。
/// 不加 @MainActor(遵守 CLAUDE.md);跨线程状态用 Task { @MainActor } 回写。
@Observable
final class ReconnectCoordinator: @unchecked Sendable {
    var status: ConnectionStatus = .offline

    private let probe: ServerProbe
    private let bonjour: BonjourBrowser
    private var isRunning = false

    init(probe: ServerProbe = HTTPServerProbe(), bonjour: BonjourBrowser = BonjourBrowser()) {
        self.probe = probe
        self.bonjour = bonjour
    }

    /// 主入口。`saved` 为上次保存的地址(可为 nil);`token` 必须有(否则未配对,直接返回)。
    /// `adopt` 由 AppState 提供:用给定地址建立连接(创建 APIClient + WS)。
    /// `isConnected` 读当前 WS 状态;`authOutcome` 读最近一次认证结果。
    @MainActor
    func attemptReconnect(
        saved: ConnectionCandidate?,
        publicFallback: ConnectionCandidate? = nil,
        token: String,
        adopt: @escaping @MainActor (ConnectionCandidate) -> Void,
        isConnected: @escaping @MainActor () -> Bool,
        authOutcome: @escaping @MainActor () -> WebSocketManager.AuthOutcome?
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // ① 试上次 IP
        if let saved {
            status = .connecting
            if await probe.isReachable(host: saved.host, port: saved.port, secure: saved.secure, fingerprint: saved.fingerprint) {
                if await tryCandidate(saved, adopt: adopt, isConnected: isConnected, authOutcome: authOutcome) {
                    status = .connected
                    return
                }
            }
        }

        // ② Bonjour 发现
        status = .searching
        let discovered = await bonjour.discoverOnce(timeout: 6)
        let candidates = ReconnectPlanner.candidates(saved: nil, discovered: discovered)
            .filter { $0 != saved } // 上次 IP 已试过

        // ③ 逐个试连(LAN)
        for c in candidates {
            guard await probe.isReachable(host: c.host, port: c.port, secure: c.secure, fingerprint: c.fingerprint) else { continue }
            if await tryCandidate(c, adopt: adopt, isConnected: isConnected, authOutcome: authOutcome) {
                status = .connected
                return
            }
        }

        // ④ 公网中继兜底:LAN 全失败后,若配了公网端点 + fingerprint 则试 HTTPS pinned。
        if let pub = publicFallback {
            if await probe.isReachable(host: pub.host, port: pub.port, secure: pub.secure, fingerprint: pub.fingerprint) {
                if await tryCandidate(pub, adopt: adopt, isConnected: isConnected, authOutcome: authOutcome) {
                    status = .connected
                    return
                }
            }
        }

        status = .offline
    }

    /// 用某候选建连,最多等 5s:WS 认证通过返回 true;被拒(4003)/超时返回 false。
    @MainActor
    private func tryCandidate(
        _ c: ConnectionCandidate,
        adopt: @escaping @MainActor (ConnectionCandidate) -> Void,
        isConnected: @escaping @MainActor () -> Bool,
        authOutcome: @escaping @MainActor () -> WebSocketManager.AuthOutcome?
    ) async -> Bool {
        adopt(c)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isConnected() { return true }
            if authOutcome() == .rejected { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return isConnected()
    }
}
