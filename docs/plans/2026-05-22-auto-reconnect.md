# 局域网自动重连 实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.
> 设计文档:`docs/plans/2026-05-22-auto-reconnect-design.md`

**Goal:** 手机回到同一 WiFi 时,无需重新扫码/粘贴 token 即可自动连上桌面端,即使 Mac 的 IP 变了。

**Architecture:** token 复用(桌面端 token 固定),IP 变了用 Bonjour 重新发现并落地。新增 `ReconnectCoordinator` 编排「先试上次 IP → 失败则 Bonjour 发现 → 逐个候选试连,WS 认证通过者胜出」;新增 `NetworkPathMonitor` 在网络可用时主动触发;token 从明文 UserDefaults 迁到 Keychain。纯逻辑(Keychain 读写+迁移、候选合并、可达筛选)走 TDD,网络/Bonjour/生命周期手动联调。

**Tech Stack:** Swift 6 (strict concurrency)、SwiftUI、`Network.framework`(NWBrowser/NWPathMonitor/NWConnection)、`Security`(Keychain)、XCTest、XcodeGen。

**铁律(来自 CLAUDE.md):**
- `@Observable` 类**不得**加 `@MainActor`(否则 AttributeGraph 后台访问崩溃)。
- 后台回调切主线程用 `Task { @MainActor }`,不用 `MainActor.assumeIsolated`。
- 新增 `.swift` 文件靠 `xcodegen generate` 重新生成工程(已安装 `/opt/homebrew/bin/xcodegen`),不手改 pbxproj。

**全局命令:**
- 重新生成工程:`xcodegen generate`
- 构建:`xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
- 测试:`xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`

**Git 提交约定(已核实,与下文各 Task 里的 git 命令相比以此为准):**
- `DeepSeno.xcodeproj/project.pbxproj` 与 `DeepSeno/Info.plist` **是被 git 跟踪的**(早于 `.gitignore` 的 `*.xcodeproj/` 规则,gitignore 对已跟踪文件无效)。
- 每个改动源码/`project.yml` 的任务,提交时**必须**带上重新生成的 `project.pbxproj`:`git add -f DeepSeno.xcodeproj/project.pbxproj`(已跟踪文件即便匹配忽略规则也会入栈,只是有提示)。XcodeGen 输出确定性,diff 干净;与历史习惯一致(`d850c62` 新增 .swift 时一并提交了 pbxproj)。
- `xcodegen generate` 会把 Info.plist 版本号回退成 `1.0/1`,**不要提交此回退**:提交前 `git checkout -- DeepSeno/Info.plist` 还原(版本源头在 `project.yml`,release 脚本发版时用 `plutil` 重写)。
- 每个任务提交序列:`xcodegen generate` → 构建/测试 → `git checkout -- DeepSeno/Info.plist` → `git add <源文件>` + `git add -f DeepSeno.xcodeproj/project.pbxproj` → `git commit`。

> 测试相关 TDD 步骤参考 @superpowers:test-driven-development;完工核验参考 @superpowers:verification-before-completion。

---

### Task 0: 新增轻量单元测试 target

**Files:**
- Modify: `project.yml`
- Create: `DeepSenoTests/SmokeTests.swift`

**Step 1: 在 `project.yml` 增加测试 target 与 scheme test action**

把 `schemes:` 段(第 9-16 行)改为:

```yaml
schemes:
  DeepSeno:
    build:
      targets:
        DeepSeno: all
        DeepSenoTests: [test]
    test:
      targets:
        - DeepSenoTests
    run:
      config: Debug
      executable: DeepSeno
```

在 `targets:` 段末尾(`DeepSeno` target 之后)追加:

```yaml
  DeepSenoTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - DeepSenoTests
    dependencies:
      - target: DeepSeno
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        PRODUCT_BUNDLE_IDENTIFIER: "$(DEEPSENO_BUNDLE_ID).tests"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/DeepSeno.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/DeepSeno"
        BUNDLE_LOADER: "$(TEST_HOST)"
```

> 用 hosted tests(TEST_HOST 指向 app),保证 Keychain 在模拟器测试里可用(避免 logic test 的 -34018 entitlement 报错)。

**Step 2: 写一个冒烟测试**

`DeepSenoTests/SmokeTests.swift`:

```swift
import XCTest
@testable import DeepSeno

final class SmokeTests: XCTestCase {
    func test_smoke() {
        XCTAssertTrue(true)
    }
}
```

**Step 3: 重新生成工程并跑测试**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: 构建成功,`test_smoke` PASS(`** TEST SUCCEEDED **`)。
> 若模拟器名不存在,先 `xcrun simctl list devices available | grep iPhone` 选一个可用机型替换。

**Step 4: Commit**

```bash
git add project.yml DeepSenoTests/SmokeTests.swift
git commit -m "test: add DeepSenoTests unit-test target"
```

---

### Task 1: KeychainStore —— token 读写

**Files:**
- Create: `DeepSeno/Services/KeychainStore.swift`
- Test: `DeepSenoTests/KeychainStoreTests.swift`

**Step 1: 写失败测试**

`DeepSenoTests/KeychainStoreTests.swift`:

```swift
import XCTest
@testable import DeepSeno

final class KeychainStoreTests: XCTestCase {
    let account = "deepseno_test_token"

    override func tearDown() {
        KeychainStore.deleteToken(account: account)
        super.tearDown()
    }

    func test_setAndGet_roundTrip() {
        KeychainStore.setToken("abc123", account: account)
        XCTAssertEqual(KeychainStore.token(account: account), "abc123")
    }

    func test_overwrite_updatesValue() {
        KeychainStore.setToken("first", account: account)
        KeychainStore.setToken("second", account: account)
        XCTAssertEqual(KeychainStore.token(account: account), "second")
    }

    func test_delete_removesValue() {
        KeychainStore.setToken("abc123", account: account)
        KeychainStore.deleteToken(account: account)
        XCTAssertNil(KeychainStore.token(account: account))
    }

    func test_missing_returnsNil() {
        XCTAssertNil(KeychainStore.token(account: "never_written_xyz"))
    }
}
```

**Step 2: 跑测试确认失败**

Run: `xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DeepSenoTests/KeychainStoreTests`
Expected: 编译失败(`cannot find 'KeychainStore'`)。

**Step 3: 最小实现**

`DeepSeno/Services/KeychainStore.swift`:

```swift
import Foundation
import Security

/// 用 Keychain 存敏感的配对 token(替代明文 UserDefaults)。
/// 无 access group,使用 app 默认 keychain;AfterFirstUnlock 保证后台可读。
enum KeychainStore {
    private static let service = "com.enmooy.deepseno.lan"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func token(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    static func setToken(_ token: String?, account: String) {
        guard let token, !token.isEmpty else {
            deleteToken(account: account)
            return
        }
        let data = Data(token.utf8)
        // 先删后写,避免 duplicate item / 属性不一致
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func deleteToken(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
```

**Step 4: 跑测试确认通过**

Run: `xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DeepSenoTests/KeychainStoreTests`
Expected: 4 个测试 PASS。
> 不要 `xcodegen generate` 之前忘了:新增 `.swift` 文件后必须先 `xcodegen generate` 再构建,否则文件不入编译。

**Step 5: Commit**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
git add DeepSeno/Services/KeychainStore.swift DeepSenoTests/KeychainStoreTests.swift
git commit -m "feat: add KeychainStore for token storage"
```

---

### Task 2: token 迁移 + AppState 改用 Keychain

**Files:**
- Modify: `DeepSeno/Services/KeychainStore.swift`(加迁移函数)
- Modify: `DeepSeno/ViewModels/AppState.swift`
- Test: `DeepSenoTests/KeychainStoreTests.swift`(加迁移用例)

**Step 1: 写失败测试(迁移)**

在 `KeychainStoreTests` 追加:

```swift
func test_migrateFromUserDefaults_movesAndClears() {
    let udKey = "deepseno_test_migrate_token"
    let defaults = UserDefaults.standard
    defaults.set("legacy-token", forKey: udKey)
    KeychainStore.deleteToken(account: account)

    KeychainStore.migrateTokenIfNeeded(userDefaultsKey: udKey, account: account)

    XCTAssertEqual(KeychainStore.token(account: account), "legacy-token")
    XCTAssertNil(defaults.string(forKey: udKey), "明文 token 应被清除")
}

func test_migrate_noopWhenKeychainAlreadyHasToken() {
    let udKey = "deepseno_test_migrate_token2"
    UserDefaults.standard.set("legacy", forKey: udKey)
    KeychainStore.setToken("existing", account: account)

    KeychainStore.migrateTokenIfNeeded(userDefaultsKey: udKey, account: account)

    XCTAssertEqual(KeychainStore.token(account: account), "existing", "已有则不覆盖")
    // 仍应清掉明文
    XCTAssertNil(UserDefaults.standard.string(forKey: udKey))
}
```

**Step 2: 跑测试确认失败**(`cannot find 'migrateTokenIfNeeded'`)

**Step 3: 实现迁移**

在 `KeychainStore` 加:

```swift
/// 一次性迁移:把旧的明文 UserDefaults token 移入 Keychain,然后清除明文。
/// Keychain 已有 token 时不覆盖,但仍清除明文残留。
static func migrateTokenIfNeeded(userDefaultsKey: String, account: String) {
    let defaults = UserDefaults.standard
    guard let legacy = defaults.string(forKey: userDefaultsKey), !legacy.isEmpty else { return }
    if token(account: account) == nil {
        setToken(legacy, account: account)
    }
    defaults.removeObject(forKey: userDefaultsKey)
}
```

**Step 4: 跑测试确认通过**(6 个用例全 PASS)

**Step 5: AppState 改用 Keychain**

修改 `DeepSeno/ViewModels/AppState.swift`:

- 加常量(在第 44 行 `tokenKey` 附近):
```swift
    private let tokenAccount = "deepseno_lan_token"
```
- `connect(host:port:token:)` 里把 token 持久化改成 Keychain(替换第 64 行 `UserDefaults.standard.set(token, forKey: tokenKey)`):
```swift
        UserDefaults.standard.set(host, forKey: hostKey)
        UserDefaults.standard.set(port, forKey: portKey)
        KeychainStore.setToken(token, account: tokenAccount)
```
- `disconnect()` 里清除(替换第 96 行 `UserDefaults.standard.removeObject(forKey: tokenKey)`):
```swift
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: portKey)
        KeychainStore.setToken(nil, account: tokenAccount)
```
- `init()` 里在 `loadSavedConnection()` 之前先迁移(第 48 行前):
```swift
        KeychainStore.migrateTokenIfNeeded(userDefaultsKey: tokenKey, account: tokenAccount)
```
- `loadSavedConnection()` 改成从 Keychain 读 token(替换第 108-114 行):
```swift
    private func loadSavedConnection() {
        guard let host = UserDefaults.standard.string(forKey: hostKey),
              let token = KeychainStore.token(account: tokenAccount) else { return }
        let port = UserDefaults.standard.integer(forKey: portKey)
        guard port > 0 else { return }
        connect(host: host, port: port, token: token)
    }
```

**Step 6: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:DeepSenoTests/KeychainStoreTests
```
Expected: 构建成功,测试 PASS。

**Step 7: Commit**

```bash
git add DeepSeno/Services/KeychainStore.swift DeepSeno/ViewModels/AppState.swift DeepSenoTests/KeychainStoreTests.swift
git commit -m "feat: store LAN token in Keychain, migrate from UserDefaults"
```

---

### Task 3: ReconnectPlanner —— 候选合并(纯逻辑)

**Files:**
- Create: `DeepSeno/Services/ReconnectPlanner.swift`
- Test: `DeepSenoTests/ReconnectPlannerTests.swift`

**Step 1: 写失败测试**

`DeepSenoTests/ReconnectPlannerTests.swift`:

```swift
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
```

**Step 2: 跑测试确认失败**

**Step 3: 最小实现**

`DeepSeno/Services/ReconnectPlanner.swift`:

```swift
import Foundation

/// 一个待尝试的连接目标。
struct ConnectionCandidate: Equatable, Sendable {
    let host: String
    let port: Int
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
```

**Step 4: 跑测试确认通过**(4 个 PASS)

**Step 5: Commit**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
git add DeepSeno/Services/ReconnectPlanner.swift DeepSenoTests/ReconnectPlannerTests.swift
git commit -m "feat: add ReconnectPlanner candidate merge logic"
```

---

### Task 4: ServerProbe —— 可达性探测 + 首个可达候选选择

抽象出 `ServerProbe` 协议(可注入假实现做单测),真实实现用 `/api/ping` 短超时。
「选第一个可达候选」的迭代逻辑做成可测纯异步函数。

**Files:**
- Create: `DeepSeno/Services/ServerProbe.swift`
- Test: `DeepSenoTests/ServerProbeSelectionTests.swift`

**Step 1: 写失败测试(用假 probe 测选择逻辑)**

`DeepSenoTests/ServerProbeSelectionTests.swift`:

```swift
import XCTest
@testable import DeepSeno

private struct FakeProbe: ServerProbe {
    let reachableHosts: Set<String>
    func isReachable(host: String, port: Int) async -> Bool {
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
```

**Step 2: 跑测试确认失败**

**Step 3: 实现协议、选择器、真实探测**

`DeepSeno/Services/ServerProbe.swift`:

```swift
import Foundation

/// 探测某地址是否有可达的 DeepSeno 桌面端(注入用,便于单测)。
protocol ServerProbe: Sendable {
    func isReachable(host: String, port: Int) async -> Bool
}

/// 纯逻辑:按候选顺序返回第一个可达的(可注入假 probe 单测)。
enum ServerProbeSelector {
    static func firstReachable(_ candidates: [ConnectionCandidate], probe: ServerProbe) async -> ConnectionCandidate? {
        for c in candidates {
            if await probe.isReachable(host: c.host, port: c.port) {
                return c
            }
        }
        return nil
    }
}

/// 真实探测:对 /api/ping 发短超时 GET。桌面端该端点无需鉴权,只确认「有台 DeepSeno 在」。
struct HTTPServerProbe: ServerProbe {
    var timeout: TimeInterval = 2.5

    func isReachable(host: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/api/ping") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
```

**Step 4: 跑测试确认通过**(3 个 PASS)

**Step 5: Commit**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
git add DeepSeno/Services/ServerProbe.swift DeepSenoTests/ServerProbeSelectionTests.swift
git commit -m "feat: add ServerProbe reachability + candidate selection"
```

---

### Task 5: BonjourBrowser —— 一次性「发现+解析」便捷方法

给 `BonjourBrowser` 加一个无 UI、带整体超时、自动解析所有候选 host/port 的 async 方法,
供 coordinator 调用。（手动联调,无单测。）

**Files:**
- Modify: `DeepSeno/Services/BonjourBrowser.swift`

**Step 1: 加 `discoverOnce`**

在 `BonjourBrowser` 内追加(保留现有 UI 用的 `startBrowsing/stopBrowsing/resolve` 不动):

```swift
    /// 一次性发现并解析所有 _deepseno._tcp 服务,返回 (host, port) 候选。
    /// 整体超时 `timeout` 秒;期间收集到的服务都尝试解析。无 UI 依赖。
    func discoverOnce(timeout: TimeInterval = 6) async -> [ConnectionCandidate] {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_deepseno._tcp", domain: nil), using: params)

        // 收集发现的 endpoint
        let box = EndpointBox()
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.compactMap { result -> NWEndpoint? in
                if case .service = result.endpoint { return result.endpoint }
                return nil
            }
            box.set(endpoints)
        }
        browser.start(queue: .global(qos: .userInitiated))

        // 等待 timeout 收集
        try? await Task.sleep(for: .seconds(timeout))
        let endpoints = box.get()
        browser.cancel()

        // 并发解析每个 endpoint 的 host/port
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
```

在文件末尾追加两个线程安全小工具(`@unchecked Sendable` 锁保护盒,符合 CLAUDE.md 跨线程数据约定):

```swift
/// 跨线程收集 endpoint 的锁保护盒。
private final class EndpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [NWEndpoint] = []
    func set(_ e: [NWEndpoint]) { lock.lock(); endpoints = e; lock.unlock() }
    func get() -> [NWEndpoint] { lock.lock(); defer { lock.unlock() }; return endpoints }
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
```

**Step 2: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功,无 strict-concurrency 报错。

**Step 3: Commit**

```bash
git add DeepSeno/Services/BonjourBrowser.swift
git commit -m "feat: add headless one-shot Bonjour discovery with timeout"
```

---

### Task 6: WebSocketManager —— 暴露认证结果信号

coordinator「逐个试连」需要知道某候选的 token 是否被接受。利用现有逻辑:
`connected` 事件 = 成功,close code `4003` = 拒绝。把这两个状态暴露出来。

**Files:**
- Modify: `DeepSeno/Services/WebSocketManager.swift`

**Step 1: 加可观察的认证状态**

在 `WebSocketManager` 加属性(第 6 行 `lastEvent` 附近):

```swift
    /// 最近一次连接的认证结果,供 ReconnectCoordinator 逐个试连时判定。
    /// connect() 调用时重置为 nil。
    enum AuthOutcome: Sendable { case accepted, rejected }
    var authOutcome: AuthOutcome?
```

- `connect(host:port:token:)` 开头(第 27 行 `closeExisting()` 后)重置:
```swift
        self.authOutcome = nil
```
- `handleMessage` 的 `case "connected":`(第 127 行)里,设 `isConnected = true` 之后加:
```swift
            authOutcome = .accepted
```
- `receiveLoop` 里检测到 `task.closeCode.rawValue == 4003`(第 112-114 行)处,在 `return` 前加:
```swift
                    if task.closeCode.rawValue == 4003 {
                        self.authOutcome = .rejected
                        return
                    }
```

**Step 2: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功。

**Step 3: Commit**

```bash
git add DeepSeno/Services/WebSocketManager.swift
git commit -m "feat: expose WebSocket auth outcome for reconnect probing"
```

---

### Task 7: ConnectionStatus + ReconnectCoordinator 编排

**Files:**
- Create: `DeepSeno/Services/ReconnectCoordinator.swift`
- Modify: `DeepSeno/ViewModels/AppState.swift`

**Step 1: 定义状态枚举与 coordinator**

`DeepSeno/Services/ReconnectCoordinator.swift`:

```swift
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
            if await probe.isReachable(host: saved.host, port: saved.port) {
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

        // ③ 逐个试连
        for c in candidates {
            guard await probe.isReachable(host: c.host, port: c.port) else { continue }
            if await tryCandidate(c, adopt: adopt, isConnected: isConnected, authOutcome: authOutcome) {
                status = .connected
                return
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
```

**Step 2: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功。

**Step 3: Commit**

```bash
git add DeepSeno/Services/ReconnectCoordinator.swift
git commit -m "feat: add ReconnectCoordinator orchestration"
```

---

### Task 8: AppState 接入 coordinator

**Files:**
- Modify: `DeepSeno/ViewModels/AppState.swift`

**Step 1: 持有 coordinator 并暴露重连入口**

- 在属性区(第 16 行 `cacheManager` 附近)加:
```swift
    let reconnectCoordinator = ReconnectCoordinator()
```
- `init()` 把直接 `loadSavedConnection()` 改成异步尝试重连:
```swift
    init() {
        notificationService.requestAuthorization()
        KeychainStore.migrateTokenIfNeeded(userDefaultsKey: tokenKey, account: tokenAccount)
        Task { @MainActor in await self.reconnectIfPossible() }
    }
```
- 新增方法(替换原 `loadSavedConnection()`):
```swift
    /// 若本地有 token,跑自动重连(先试上次 IP,失败则 Bonjour 发现+逐个试连)。
    @MainActor
    func reconnectIfPossible() async {
        guard let token = KeychainStore.token(account: tokenAccount) else { return }
        let saved: ConnectionCandidate? = {
            guard let host = UserDefaults.standard.string(forKey: hostKey) else { return nil }
            let port = UserDefaults.standard.integer(forKey: portKey)
            guard port > 0 else { return nil }
            return ConnectionCandidate(host: host, port: port)
        }()

        await reconnectCoordinator.attemptReconnect(
            saved: saved,
            token: token,
            adopt: { [weak self] c in self?.connect(host: c.host, port: c.port, token: token) },
            isConnected: { [weak self] in self?.webSocket.isConnected ?? false },
            authOutcome: { [weak self] in self?.webSocket.authOutcome }
        )
    }
```
> 注意:`connect()` 内已会持久化新 host/port,所以重连到新 IP 后会自动落地。

**Step 2: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功。

**Step 3: Commit**

```bash
git add DeepSeno/ViewModels/AppState.swift
git commit -m "feat: drive auto-reconnect from AppState on launch"
```

---

### Task 9: NetworkPathMonitor —— 网络可用即触发

**Files:**
- Create: `DeepSeno/Services/NetworkPathMonitor.swift`
- Modify: `DeepSeno/ViewModels/AppState.swift`
- Modify: `DeepSeno/DeepSenoApp.swift`

**Step 1: 实现监听器**

`DeepSeno/Services/NetworkPathMonitor.swift`:

```swift
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
```

**Step 2: AppState 持有并接线**

在 `AppState` 属性区加:
```swift
    private let pathMonitor = NetworkPathMonitor()
```
在 `init()` 末尾(`Task` 之后)加:
```swift
        pathMonitor.onBecameSatisfied = { [weak self] in
            Task { @MainActor in
                guard let self, !self.webSocket.isConnected else { return }
                await self.reconnectIfPossible()
            }
        }
        pathMonitor.start()
```

**Step 3: 前台也触发重连(替换 DeepSenoApp 旧逻辑)**

`DeepSeno/DeepSenoApp.swift` 的 `.onChange(of: scenePhase)`(第 24-39 行)改为:
```swift
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                if let api = appState.apiClient {
                    Task { await appState.captureQueue.processQueue(apiClient: api) }
                }
                // 未连接时跑完整自动重连(会先试上次 IP,失败则 Bonjour 发现)
                if !appState.webSocket.isConnected {
                    Task { @MainActor in await appState.reconnectIfPossible() }
                }
            }
        }
```

**Step 4: 构建验证**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功。

**Step 5: Commit**

```bash
git add DeepSeno/Services/NetworkPathMonitor.swift DeepSeno/ViewModels/AppState.swift DeepSeno/DeepSenoApp.swift
git commit -m "feat: trigger auto-reconnect on network availability and foreground"
```

---

### Task 10: ConnectionBadge —— 显示「正在查找电脑…」

让用户看到 App 在自动找电脑,而不是误以为要重扫。

**Files:**
- Read first: `DeepSeno/Views/Common/ConnectionBadge.swift`(了解现有二态渲染)
- Modify: `DeepSeno/Views/Common/ConnectionBadge.swift`
- 可能 Modify: `DeepSeno/Theme/I18n.swift`(加「正在查找电脑…」文案,中英各一条)

**Step 1: 先读现有实现**

Run: 读 `DeepSeno/Views/Common/ConnectionBadge.swift` 全文,确认它当前如何取 `appState.isConnected`。

**Step 2: 改为读 `reconnectCoordinator.status`**

把徽标的状态来源从 `appState.isConnected`(二态)改为 `appState.reconnectCoordinator.status`,映射:
- `.connected` → 现有「已连接」绿点样式
- `.connecting` / `.searching` → 黄点 + 文案(`.searching` 用「正在查找电脑…」/「Looking for your computer…」,`.connecting` 用现有「连接中」)
- `.offline` → 现有「未连接」灰点样式

> 保持与现有 `DeepSenoTheme` 配色一致,只新增 `searching` 这一中间态的文案与黄点。具体取色/字体跟随该文件现有写法,不要新造样式体系。

**Step 3: 文案**

在 `I18n.swift` 的中/英文案结构里各加一条 `lookingForComputer`(中:「正在查找电脑…」,英:「Looking for your computer…」),在徽标里引用。

**Step 4: 构建 + 真机/模拟器目视**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: 构建成功;运行后断开桌面端时徽标显示「正在查找电脑…」,连上后变绿。

**Step 5: Commit**

```bash
git add DeepSeno/Views/Common/ConnectionBadge.swift DeepSeno/Theme/I18n.swift
git commit -m "feat: show 'looking for computer' state in ConnectionBadge"
```

---

### Task 11: 手动联调 + 全量回归

> 参考 @superpowers:verification-before-completion:先跑命令看输出,再下结论。

**Step 1: 全量单测 + 构建**

```bash
cd /Users/mac/workspace/deepseno-ios && xcodegen generate
xcodebuild test -scheme DeepSeno -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
Expected: 全部测试 PASS,`** TEST SUCCEEDED **`。

**Step 2: 真机联调脚本(逐项记录通过/失败)**

需要真机 + 运行中的 voicebrain 桌面端,且两者同 WiFi:
1. **冷启动自动连**:桌面端开着,杀掉 App 重开 → 应自动连上(不扫码)。徽标先「连接中/查找中」后变绿。
2. **IP 变更后重连**:让 Mac 换 IP(关开 WiFi 触发 DHCP 重新分配,或路由器改租约)→ 把 App 切后台再切回 → 应「正在查找电脑…」后自动连上,无需扫码。验证 `UserDefaults` 里的 host 已更新为新 IP。
3. **网络可用即连**:断开手机 WiFi(保持 App 前台)→ 重新连上同一 WiFi → 应自动重连(NWPathMonitor 触发),不必切后台。
4. **电脑离线**:关掉桌面端 → App 应显示「未连接」(.offline),不弹错误、不要求扫码;重开桌面端后(切后台回来或网络抖动)应自动恢复。
5. **token 失效**(可选):删掉桌面端 `~/.../deepseno/lan-token` 让它换 token → App 应在 WS 4003 后提示「需要重新配对」(此场景仅当本计划包含该提示;若未做,记录为已知限制)。
6. **Keychain 迁移**:用旧版本(明文 token)升级到新版本 → 首启后应正常连上,且 `UserDefaults` 里旧 `deepseno_token` 已被清除(可用 Xcode 调试或临时日志确认)。

**Step 3: 回归既有功能**

确认录音上传、实时转写校正、Sources/Chat/Briefing 等仍正常(连接信息变更不应影响这些)。

**Step 4: 最终提交(如有联调期间的修复)**

```bash
git add -A && git commit -m "test: manual integration pass for auto-reconnect"
```

---

## 完成标准

- 同一 WiFi 下,Mac 换 IP 后 App 仍能自动连上,全程不扫码/不粘贴。
- 一连上 WiFi 就主动重连,无需切后台。
- 电脑离线时静默显示「未连接」,不打扰;电脑回来自动恢复。
- token 存于 Keychain,旧明文已清除。
- 全量单测 PASS,模拟器构建通过。

## 已知取舍 / 未来工作

- **serverName 多台精确匹配**:本期按 YAGNI 不做;多台电脑靠「逐个试连 + WS 认证」区分,够用。将来若家里常驻多台,可加 Bonjour 实例名记忆做确定性匹配。
- **token 失效提示 UI**:若 Task 11-5 未实现明确提示,记为已知限制(正常重启桌面端不会触发,因 token 固定)。
