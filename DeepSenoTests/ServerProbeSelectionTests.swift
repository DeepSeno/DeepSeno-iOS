import XCTest
@testable import DeepSeno

private struct FakeProbe: ServerProbe {
    let reachableHosts: Set<String>
    func isReachable(host: String, port: Int, secure: Bool, fingerprint: String?) async -> Bool {
        reachableHosts.contains(host)
    }
}

final class ServerProbeSelectionTests: XCTestCase {
    func test_picksFirstReachable() async {
        let probe = FakeProbe(reachableHosts: ["192.168.1.9"])
        let candidates = [
            ConnectionCandidate(host: "192.168.1.5", port: 18526), // 不可达
            ConnectionCandidate(host: "192.168.1.9", port: 18526), // 可达
        ]
        let picked = await ServerProbeSelector.firstReachable(candidates, probe: probe)
        XCTAssertEqual(picked, candidates[1])
    }

    func test_returnsNilWhenNoneReachable() async {
        let probe = FakeProbe(reachableHosts: [])
        let candidates = [ConnectionCandidate(host: "10.0.0.1", port: 18526)]
        let picked = await ServerProbeSelector.firstReachable(candidates, probe: probe)
        XCTAssertNil(picked)
    }

    func test_prefersEarlierCandidate() async {
        let probe = FakeProbe(reachableHosts: ["192.168.1.5", "192.168.1.9"])
        let candidates = [
            ConnectionCandidate(host: "192.168.1.5", port: 18526),
            ConnectionCandidate(host: "192.168.1.9", port: 18526),
        ]
        let picked = await ServerProbeSelector.firstReachable(candidates, probe: probe)
        XCTAssertEqual(picked, candidates[0])
    }

}
