# 局域网自动重连设计(无需重复扫码)

> 日期:2026-05-22 · 方案 A(智能重连)+ Token 迁 Keychain

## 问题

手机首次通过扫码 / 复制粘贴配对成功后,下次回到同一个 WiFi 仍然要求重新
扫码或粘贴 token 才能连上。

### 根因(已通过两端代码确认)

- **桌面端(voicebrain)token 是固定的**:`src/main/server/auth.ts:31-44` 一次
  生成、持久化到 `~/.../deepseno/lan-token`,重启复用,不重新生成。
  → 手机里存的 token **长期有效**。
- **桌面端 IP 是路由器动态分配的,会变**(`lan-server.ts:745-762`
  `getLocalIP()` 取当前网卡地址写进二维码)。端口固定 `18526`,绑定 `0.0.0.0`。
- **手机端存的是写死的旧 IP**(`AppState.swift:42-44` 的
  `deepseno_host/port/token`)。IP 一变,自动连旧 IP 超时失败。
- `WebSocketManager`(`WebSocketManager.swift:180-190`)虽有指数退避重连循环,
  但**永远只连同一个 host/port,从不重新解析**;token 错(close `4003`)才停。
- 两端其实都已具备 Bonjour:桌面广播 `_deepseno._tcp`
  (`lan-server.ts:682-694`,实例名 `DeepSeno-{hostname}`,TXT `version=2.0`),
  手机有 `BonjourBrowser`,但只在设置页**手动**用,自动连失败时不会触发,且还
  要求再输一次 token。

**结论:纯 iOS 端可解。** token 复用,IP 靠 Bonjour 找回来即可。

## 目标 / 非目标

**目标**
- 同一网络下回到 App,**无需任何扫码 / 粘贴**即可自动连上,即使 Mac 的 IP 变了。
- 一连上 WiFi 就主动尝试,不必先切后台再切回。
- token 不再明文存储。

**非目标(YAGNI)**
- 跨网络/公网穿透、固定 IP 引导、`.local` 主机名解析(方案 C)——不做。
- 桌面端不做任何改动。

## 方案选型

| 方案 | 说明 | 取舍 |
|---|---|---|
| **A 智能重连(选定)** | IP 优先 + Bonjour 自动兜底 + 网络变化监听 | 快(优先 IP)、稳(Bonjour 兜底)、主动(网络监听);改动集中 iOS |
| B 纯 Bonjour | 每次启动都重新发现 | 简单但启动慢 1–3s;电脑关机时无旧 IP 可先试 |
| C 固定 IP / `.local` | 用户配静态 IP 或主机名解析 | 需用户配路由器,或 `.local` 在部分网络不稳 |

## 核心机制

### 触发入口(三处,统一调用 `attemptReconnect()`)
1. App 启动:`AppState.init`(替换现有 `loadSavedConnection` 的直连)。
2. 回到前台:`DeepSenoApp` 的 `scenePhase == .active`。
3. **网络变化**:新增 `NWPathMonitor`,路径变为 `.satisfied` 且当前未连接时触发。

### `attemptReconnect()` 流程(仅当本地存有 token 时执行)

```
① 快速探测上次的 IP
     对 saved host:port 发 GET /api/ping,超时 ~2.5s(独立短超时 URLSession)
     └─ 200 → connect()                       ← 最常见、最快路径
② 探测失败 → Bonjour 发现 _deepseno._tcp(整体超时 ~6s)
     解析每个候选的当前 host/port
     按候选顺序「用已存 token」逐个尝试建立 WS:
        收到 "connected" 事件 → 成功 → 落地新 host/port → 完成
        收到 4003 / 超时       → 试下一个候选
③ 全部失败 → 标记 .offline,静默;等下一次网络变化 / 前台再试(不打扰用户)
```

- **token 始终复用,绝不再触发扫码。**
- **多台电脑**:用「WS 能否认证成功」作为「是不是我那台」的判据,连错会
  `4003` 自动跳下一个;都不通则回退到设置页发现列表(token 已存,仍不用扫码)。
- 找到新 IP 后写回 UserDefaults,下次①即可命中。

## 组件改动

| 组件 | 类型 | 改动 |
|---|---|---|
| `KeychainStore` | 新增 | `Security` 框架 `kSecClassGenericPassword` 读写 token;首启从旧 `deepseno_token`(UserDefaults)迁移后清除明文 |
| `ReconnectCoordinator` | 新增 | 编排 ①②③。**遵守铁律:`@Observable` 不加 `@MainActor`**;后台回调用 `Task { @MainActor }` 切回 |
| `NetworkPathMonitor` | 新增 | 包 `NWPathMonitor`,网络可用时回调 coordinator;在后台 queue 起,marshal 回主线程 |
| `BonjourBrowser` | 改 | 增加「一次性发现+解析+整体超时」便捷方法,支持无 UI 调用;`resolve` 一并回传实例名 |
| `AppState` | 改 | `connect/disconnect/loadSavedConnection`:token 走 Keychain、host/port 走 UserDefaults;持有并驱动 coordinator;暴露连接状态 |
| `WebSocketManager` | 改 | 暴露足够的状态(连接成功/`4003`/超时)供 coordinator 判定候选;可被 coordinator 用新 host/port 重置 |
| `ConnectionBadge` | 改 | 由「已连接/未连接」二态扩展为 `connecting / searching / connected / offline` |

### 存储划分
- **Keychain**:`token`(敏感)。
- **UserDefaults**:`host`、`port`、可选 `serverName`(不敏感)。
- 迁移:首启若 UserDefaults 有 `deepseno_token` 且 Keychain 无 → 写入 Keychain
  并 `removeObject` 清除明文;host/port 保持原 key。

### 连接状态枚举(供 UI)
```
enum ConnectionStatus { case connecting, searching, connected, offline }
```
`searching` 态让用户看到「正在查找电脑…」,明确知道在自动找,而不是误以为要重扫。

## 边界情况

- **电脑没开机 / 不在同网络** → 发现不到服务 → `.offline`,静默,等下次网络
  变化再试。不弹窗。
- **token 真失效**(用户手动删了桌面端 `lan-token`)→ WS `4003` → 唯一需要
  重新配对的情况 → 明确提示「需要重新配对」。正常重启电脑不触发。
- **多台电脑** → 逐个 token 试连,认证通过的才用;都不通回退设置页列表。

## 测试

- **单元**
  - `KeychainStore` 读写往返;从 UserDefaults 迁移后明文已清除。
  - 候选匹配:单台直选 / 多台按 token 筛 / 全失败回退。
- **手动联调**
  - 切 WiFi 让 Mac 换 IP → 手机自动重连,**不扫码**。
  - 电脑关机 → `.offline` 态;开机/回网 → 自动恢复。
  - 切换网络 → 自动恢复。
  - Keychain 迁移后旧明文 token 已清除。
- **并发**:`NWPathMonitor` 回调在后台 queue,按既有模式 `Task { @MainActor }`
  切回,符合 Swift 6 strict concurrency 与 `@Observable` 无 `@MainActor` 约束。

## 风险

- `NWConnection` 解析在 peer-to-peer / 某些 AP 隔离网络下可能拿不到 host —
  已有 `resolve` 逻辑,加超时兜底即可,失败则视作该候选不可用。
- Keychain 在首次安装/恢复备份时的可用性:用 `kSecAttrAccessibleAfterFirstUnlock`
  保证后台也可读。
