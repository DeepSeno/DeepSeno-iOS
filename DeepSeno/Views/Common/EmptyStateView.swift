import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(DeepSenoTheme.textTertiary)

            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(DeepSenoTheme.textPrimary)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(DeepSenoTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .padding(40)
        .offset(y: -30)
    }
}
