import SwiftUI

enum SettingsSheet: String, Identifiable {
    case pairing
    case manualConnect
    case bonjourConnect

    var id: String { rawValue }
}

@Observable
class SettingsViewModel: @unchecked Sendable {
    var activeSheet: SettingsSheet?
    var showQueueManagement = false

    // Manual connect form
    var manualHost = ""
    var manualPort = "18526"
    var manualToken = ""
    var connectError: String?

    // Public access (relay) form. Persisted toggle via @AppStorage in the view;
    // the fields themselves are transient form state mirrored into ConnectionInfo.
    static let allowPublicAccessKey = "deepseno_allow_public_access"
    var manualPublicHost = ""
    var manualPublicPort = ""
    var manualFingerprint = ""
    var allowPublicAccess = false

    // Bonjour
    var selectedBonjourDevice: String?

    func manualConnect(appState: AppState) {
        let t = AppLanguage.current == .zh ? Strings.zh : Strings.en
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            connectError = t.hostRequired
            return
        }
        // Public-relay candidate. Only carried when the toggle is on AND
        // host + port + fingerprint are all provided & valid. fingerprint is
        // required here — without it cert pinning has nothing to pin and the
        // public HTTPS connection can't be trusted.
        var publicHost: String? = nil
        var publicPort: Int? = nil
        var fingerprint: String? = nil
        if allowPublicAccess {
            let ph = manualPublicHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let fp = manualFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ph.isEmpty, !fp.isEmpty {
                guard let pp = Int(manualPublicPort), (1...65535).contains(pp) else {
                    connectError = t.invalidPort
                    return
                }
                publicHost = ph
                publicPort = pp
                fingerprint = fp
            }
        }
        let hasPublic = (publicHost != nil && publicPort != nil && fingerprint != nil)
        // LAN is optional when a complete public endpoint is supplied — supports
        // the "away from home, only know the relay address" case. But if LAN host
        // IS provided its port must be valid.
        var lanPort = 0
        if !host.isEmpty {
            guard let p = Int(manualPort), (1...65535).contains(p) else {
                connectError = t.invalidPort
                return
            }
            lanPort = p
        } else if !hasPublic {
            // Neither a LAN host nor a complete public endpoint → can't connect.
            connectError = t.hostRequired
            return
        }
        connectError = nil
        Task { await appState.connect(info: ConnectionInfo(
            host: host, port: lanPort, token: token, fingerprint: fingerprint, relay: nil
        )) }
        activeSheet = nil
    }

    func connectFromBonjour(appState: AppState) {
        let t = AppLanguage.current == .zh ? Strings.zh : Strings.en
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !token.isEmpty else {
            connectError = t.hostRequired
            return
        }
        guard let port = Int(manualPort), (1...65535).contains(port) else {
            connectError = t.invalidPort
            return
        }
        connectError = nil
        appState.connect(host: host, port: port, token: token)
        activeSheet = nil
    }

    func pasteConnectionJSON() {
        let t = AppLanguage.current == .zh ? Strings.zh : Strings.en
        // iOS 16+ may return nil when the user dismisses the system "Allow
        // paste?" prompt, or when "Paste from Other Apps" is set to Deny in
        // Settings. Treat that as a distinct error so the user knows to retry
        // / change the setting rather than re-copy.
        let raw = (UIPasteboard.general.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            connectError = t.clipboardNoJSON
            return
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Show a snippet so the user can spot copy/format issues (e.g. an
            // accidental URL, a JSON array, or extra wrapping).
            let preview = raw.prefix(40)
            let ellipsis = raw.count > 40 ? "…" : ""
            connectError = "\(t.clipboardNoJSON)：「\(preview)\(ellipsis)」"
            return
        }
        if let host = json["host"] as? String { manualHost = host }
        if let port = json["port"] as? Int { manualPort = "\(port)" }
        else if let port = json["port"] as? String { manualPort = port }
        if let token = json["token"] as? String { manualToken = token }
        // Public-relay fields (optional in QR JSON). When present, surface them
        // in the form and flip the toggle on so the user sees they're in use.
        if let ph = json["publicHost"] as? String { manualPublicHost = ph }
        if let pp = json["publicPort"] as? Int { manualPublicPort = "\(pp)" }
        else if let pp = json["publicPort"] as? String { manualPublicPort = pp }
        if let fp = json["fingerprint"] as? String { manualFingerprint = fp }
        if !manualPublicHost.isEmpty { allowPublicAccess = true }
        connectError = nil
    }

    func resetForm() {
        manualHost = ""
        manualPort = "18526"
        manualToken = ""
        manualPublicHost = ""
        manualPublicPort = ""
        manualFingerprint = ""
        connectError = nil
        selectedBonjourDevice = nil
    }
}
