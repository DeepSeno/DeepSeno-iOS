import XCTest
@testable import DeepSeno

final class ReconnectPlannerTests: XCTestCase {
    func test_savedFirst_thenDiscovered() {
        let saved = ConnectionCandidate(host: "192.168.1.5", port: 18526)
        let discovered = [
            ConnectionCandidate(host: "192.168.1.9", port: 18526),
        ]
        let result = ReconnectPlanner.candidates(saved: saved, discovered: discovered)
        XCTAssertEqual(result, [saved, discovered[0]])
    }

    func test_dedupes_savedFromDiscovered() {
        let saved = ConnectionCandidate(host: "192.168.1.5", port: 18526)
        let discovered = [
            ConnectionCandidate(host: "192.168.1.5", port: 18526), // 同一台
            ConnectionCandidate(host: "192.168.1.9", port: 18526),
        ]
        let result = ReconnectPlanner.candidates(saved: saved, discovered: discovered)
        XCTAssertEqual(result, [saved, ConnectionCandidate(host: "192.168.1.9", port: 18526)])
    }

    func test_noSaved_returnsDiscoveredInOrder() {
        let discovered = [
            ConnectionCandidate(host: "192.168.1.9", port: 18526),
            ConnectionCandidate(host: "192.168.1.7", port: 18526),
        ]
        let result = ReconnectPlanner.candidates(saved: nil, discovered: discovered)
        XCTAssertEqual(result, discovered)
    }

    func test_empty_returnsEmpty() {
        XCTAssertEqual(ReconnectPlanner.candidates(saved: nil, discovered: []), [])
    }
}
