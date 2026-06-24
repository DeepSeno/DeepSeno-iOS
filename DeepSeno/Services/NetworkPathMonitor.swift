import Foundation
import Network

/// 监听网络可用性;路径变为 satisfied 时回调(用于「一连上 WiFi 就主动重连」)。
/// 不加 @MainActor;回调里用 Task { @MainActor } 切回(遵守 CLAUDE.md)。
final class NetworkPathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "deepseno.network.monitor")
    private var wasSatisfied = false

    /// 当网络从「不可用」变为「可用」时触发(避免重复触发同一状态)。
    var onBecameSatisfied: (@Sendable () -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            let rising = satisfied && !self.wasSatisfied
            self.wasSatisfied = satisfied
            if rising { self.onBecameSatisfied?() }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
