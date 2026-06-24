import Foundation

/// 探测某地址是否有可达的 DeepSeno 桌面端(注入用,便于单测)。
/// `secure`/`fingerprint` 用于公网中继候选:secure 时走 https + 证书 pinning。
protocol ServerProbe: Sendable {
    func isReachable(host: String, port: Int, secure: Bool, fingerprint: String?) async -> Bool
}

extension ServerProbe {
    /// 便捷重载:默认 LAN 探测(plain http,无 pinning)。
    func isReachable(host: String, port: Int) async -> Bool {
        await isReachable(host: host, port: port, secure: false, fingerprint: nil)
    }
}

/// 纯逻辑:按候选顺序返回第一个可达的(可注入假 probe 单测)。
enum ServerProbeSelector {
    static func firstReachable(_ candidates: [ConnectionCandidate], probe: ServerProbe) async -> ConnectionCandidate? {
        for c in candidates {
            if await probe.isReachable(host: c.host, port: c.port, secure: c.secure, fingerprint: c.fingerprint) {
                return c
            }
        }
        return nil
    }
}

/// 真实探测:对 /api/ping 发短超时 GET。桌面端该端点无需鉴权,只确认「有台 DeepSeno 在」。
struct HTTPServerProbe: ServerProbe {
    var timeout: TimeInterval = 2.5

    func isReachable(host: String, port: Int, secure: Bool, fingerprint: String?) async -> Bool {
        let scheme = secure ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/api/ping") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        // For the secure public endpoint, pin the cert (the self-signed desktop
        // cert won't validate against the system trust store otherwise).
        let session: URLSession
        let delegate: PinningDelegate?
        if secure, let fingerprint {
            delegate = PinningDelegate(fingerprint: fingerprint)
            session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        } else {
            delegate = nil
            session = URLSession(configuration: config)
        }
        _ = delegate // retained until this call returns via the session
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
