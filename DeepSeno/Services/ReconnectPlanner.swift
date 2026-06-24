import Foundation

/// 一个待尝试的连接目标。
/// `secure`/`fingerprint` 默认 false/nil,使既有 LAN 候选(plain HTTP)行为不变;
/// 公网中继候选会带 secure:true + fingerprint,走 HTTPS + 证书 pinning。
struct ConnectionCandidate: Equatable, Sendable {
    let host: String
    let port: Int
    var secure: Bool = false
    var fingerprint: String? = nil
}

/// 纯逻辑:把「上次保存的地址」与「Bonjour 现场发现的地址」合并成有序、去重的候选列表。
/// 顺序:上次的 IP 优先(命中最快),其后是发现的其它地址。
enum ReconnectPlanner {
    static func candidates(saved: ConnectionCandidate?, discovered: [ConnectionCandidate]) -> [ConnectionCandidate] {
        var result: [ConnectionCandidate] = []
        if let saved { result.append(saved) }
        for c in discovered where !result.contains(c) {
            result.append(c)
        }
        return result
    }
}
