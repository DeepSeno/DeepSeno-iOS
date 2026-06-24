import SwiftUI

/// Shows connection status + transport mode (LAN Direct / P2P Direct / Encrypted Relay).
/// Mirrors Android ConnectionBadge.kt.
struct ConnectionBadge: View {
    @Environment(\.i18n) private var i18n
    let isConnected: Bool
    let host: String?
    let transportMode: String  // "none" | "lan" | "p2p" | "relay"
    var reconnectStatus: ConnectionStatus = .offline

    var body: some View {
        let dotColor = isConnected ? DeepSenoTheme.accentGreen : DeepSenoTheme.accentRed
        let textColor = isConnected ? DeepSenoTheme.accentGreen : DeepSenoTheme.textSecondary
        let label = isConnected ? (host ?? i18n.t.connectedStatus) : i18n.t.disconnectedStatus

        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)

            if isConnected && transportMode != "none" {
            let modeLabel = switch transportMode {
            case "p2p": i18n.t.transportP2P
            case "relay": i18n.t.transportRelay
            case "lan": i18n.t.transportLan
            default: ""
            }
            let modeColor: Color = switch transportMode {
            case "p2p", "lan": DeepSenoTheme.accentGreen
            case "relay": Color(red: 0.96, green: 0.62, blue: 0.04)
            default: DeepSenoTheme.textSecondary
            }
            if !modeLabel.isEmpty {
                Text("·").foregroundStyle(DeepSenoTheme.textSecondary).font(.system(size: 12))
                    Text(modeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(modeColor)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(DeepSenoTheme.bgTertiary.opacity(0.8))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    var reconnectDisplay: some View { EmptyView() }
}
