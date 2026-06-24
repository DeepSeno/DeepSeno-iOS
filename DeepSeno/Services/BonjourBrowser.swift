import Foundation
import Network

struct DiscoveredDevice: Identifiable, Sendable {
    let id: String
    let name: String
    var host: String
    var port: Int
    let endpoint: NWEndpoint

    init(name: String, endpoint: NWEndpoint) {
        self.id = name
        self.name = name
        self.host = ""
        self.port = 0
        self.endpoint = endpoint
    }
}

@Observable
class BonjourBrowser: @unchecked Sendable {
    var discoveredDevices: [DiscoveredDevice] = []
    var isSearching = false

    fileprivate static let serviceTypes = ["_deepseno._tcp", "_korteqo._tcp"]

    private var browsers: [NWBrowser] = []
    private var browseResults: [String: [DiscoveredDevice]] = [:]
    private var activeServiceTypes = Set<String>()
    private var browseGeneration = 0

    func startBrowsing() {
        stopBrowsing()
        browseGeneration += 1
        let generation = browseGeneration
        activeServiceTypes = Set(Self.serviceTypes)

        for serviceType in Self.serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let devices = results.compactMap { result -> DiscoveredDevice? in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return DiscoveredDevice(name: name, endpoint: result.endpoint)
                    }
                    return nil
                }
                Task { @MainActor in
                    self?.updateBrowseResults(devices, for: serviceType, generation: generation)
                }
            }

            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleBrowserState(state, for: serviceType, generation: generation)
                }
            }

            browsers.append(browser)
            browser.start(queue: .main)
        }
    }

    @MainActor
    private func updateBrowseResults(_ devices: [DiscoveredDevice], for serviceType: String, generation: Int) {
        guard browseGeneration == generation else { return }
        browseResults[serviceType] = devices
        mergeBrowseResults()
    }

    @MainActor
    private func handleBrowserState(_ state: NWBrowser.State, for serviceType: String, generation: Int) {
        guard browseGeneration == generation else { return }
        switch state {
        case .ready:
            isSearching = true
        case .failed, .cancelled:
            activeServiceTypes.remove(serviceType)
            browseResults[serviceType] = []
            mergeBrowseResults()
            isSearching = !activeServiceTypes.isEmpty
        default:
            break
        }
    }

    @MainActor
    private func mergeBrowseResults() {
        var seen = Set<String>()
        discoveredDevices = Self.serviceTypes.flatMap { browseResults[$0] ?? [] }.filter { device in
            seen.insert(device.name).inserted
        }
    }

    func stopBrowsing() {
        browseGeneration += 1
        browsers.forEach { $0.cancel() }
        browsers = []
        browseResults = [:]
        activeServiceTypes = []
        discoveredDevices = []
        isSearching = false
    }

    /// Resolve a discovered device endpoint to get host and port
    func resolve(_ device: DiscoveredDevice, completion: @escaping @Sendable (String, Int) -> Void) {
        let connection = NWConnection(to: device.endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                if let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint {
                    let hostStr = "\(host)"
                        .replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                    completion(hostStr, Int(port.rawValue))
                }
                connection.cancel()
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }

    /// 一次性发现并解析所有 DeepSeno/Korteqo Bonjour 服务,返回 (host, port) 候选。
    /// 发现到服务后只再等一个很短的 settle 窗口即提前返回,整体以 `timeout` 秒封顶;
    /// 收集到的服务都尝试解析。无 UI 依赖。
    func discoverOnce(timeout: TimeInterval = 6) async -> [ConnectionCandidate] {
        let box = EndpointBox()
        let browsers = Self.serviceTypes.map { serviceType -> NWBrowser in
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
            browser.browseResultsChangedHandler = { results, _ in
                let endpoints = results.compactMap { result -> NWEndpoint? in
                    if case .service = result.endpoint { return result.endpoint }
                    return nil
                }
                box.set(endpoints, for: serviceType)
            }
            browser.start(queue: .global(qos: .userInitiated))
            return browser
        }

        // 轮询收集:一旦发现到服务,再多等一个很短的 settle 窗口(收集可能同时
        // 存在的其它设备)就提前返回,整体仍以 timeout 封顶。常见的单台电脑场景
        // 由「固定等满 timeout」降到约「首次发现 + settle」。没有任何服务时,
        // 行为不变 —— 等满 timeout 后返回空。
        let deadline = Date().addingTimeInterval(timeout)
        let settle: TimeInterval = 0.8
        var firstSeen: Date?
        while Date() < deadline {
            if !box.get().isEmpty {
                if firstSeen == nil { firstSeen = Date() }
                if Date().timeIntervalSince(firstSeen!) >= settle { break }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        let endpoints = box.get()
        browsers.forEach { $0.cancel() }

        // 解析每个 endpoint 的 host/port
        var candidates: [ConnectionCandidate] = []
        for endpoint in endpoints {
            if let c = await Self.resolveEndpoint(endpoint, timeout: 2.0) {
                if !candidates.contains(c) { candidates.append(c) }
            }
        }
        return candidates
    }

    /// 解析单个 endpoint 为 host/port,带超时。
    private static func resolveEndpoint(_ endpoint: NWEndpoint, timeout: TimeInterval) async -> ConnectionCandidate? {
        await withCheckedContinuation { continuation in
            let resumed = ResumeGuard()
            let connection = NWConnection(to: endpoint, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       let remote = path.remoteEndpoint,
                       case .hostPort(let host, let port) = remote {
                        let hostStr = "\(host)"
                            .replacingOccurrences(of: "%.*", with: "", options: .regularExpression)
                        if resumed.tryResume() {
                            continuation.resume(returning: ConnectionCandidate(host: hostStr, port: Int(port.rawValue)))
                        }
                    } else if resumed.tryResume() {
                        continuation.resume(returning: nil)
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    if resumed.tryResume() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            // 超时兜底
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.tryResume() {
                    connection.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// 跨线程收集 endpoint 的锁保护盒。
private final class EndpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var endpointsByService: [String: [NWEndpoint]] = [:]

    func set(_ endpoints: [NWEndpoint], for serviceType: String) {
        lock.lock()
        endpointsByService[serviceType] = endpoints
        lock.unlock()
    }

    func get() -> [NWEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        return BonjourBrowser.serviceTypes.flatMap { endpointsByService[$0] ?? [] }.filter { endpoint in
            seen.insert("\(endpoint)").inserted
        }
    }
}

/// 保证 continuation 只 resume 一次。
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
