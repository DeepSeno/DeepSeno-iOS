import SwiftUI

struct StatusBadge: View {
    @Environment(\.i18n) private var i18n
    let status: String

    private var color: Color {
        switch status {
        case "completed": DeepSenoTheme.accentGreen
        case "processing": DeepSenoTheme.accentAmber
        case "failed": DeepSenoTheme.accentRed
        default: DeepSenoTheme.textSecondary
        }
    }

    private var label: String {
        switch status {
        case "completed": i18n.t.statusCompleted
        case "processing": i18n.t.statusProcessing
        case "failed": i18n.t.statusFailed
        default: status.uppercased()
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.15), lineWidth: 0.5))
    }
}
