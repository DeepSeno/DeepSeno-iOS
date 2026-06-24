import SwiftUI

struct SourceCard: View {
    @Environment(\.i18n) private var i18n
    let recording: Recording

    var body: some View {
        HStack(spacing: 0) {
            // Colored left-edge accent strip — media type at a glance
            RoundedRectangle(cornerRadius: 2)
                .fill(iconColor)
                .frame(width: 3)
                .padding(.vertical, 8)
                .padding(.leading, 2)

            HStack(spacing: 12) {
                // Media type icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.1))
                    Image(systemName: recording.mediaIcon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 38, height: 38)

                // File info
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.fileName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let duration = recording.formattedDuration {
                            Text(duration)
                                .font(.system(size: 11, design: .monospaced))
                        } else if let pages = recording.pageCount {
                            Text("\(pages)p")
                                .font(.system(size: 11))
                        }

                        if let date = recording.recordedAt {
                            Text("·")
                            Text(formatDate(date))
                                .font(.system(size: 11))
                        }

                        StatusBadge(status: recording.status)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DeepSenoTheme.textSecondary)

                    // Tags inline
                    if hasMetadata {
                        HStack(spacing: 6) {
                            if let count = recording.extractedCount, count > 0 {
                                metaTag(icon: "tag", text: "\(count)")
                            }
                            if let speakers = recording.speakerCount, speakers > 0 {
                                metaTag(icon: "person.2", text: "\(speakers)")
                            }
                            if let words = recording.wordCount, words > 0 {
                                metaTag(icon: "text.word.spacing", text: "\(words)")
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DeepSenoTheme.textTertiary.opacity(0.6))
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
        .background(DeepSenoTheme.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DeepSenoTheme.glassBorder, lineWidth: 0.5)
        )
    }

    private var hasMetadata: Bool {
        (recording.extractedCount ?? 0) > 0
            || (recording.speakerCount ?? 0) > 0
            || (recording.wordCount ?? 0) > 0
    }

    private var iconColor: Color {
        switch recording.mediaType {
        case "audio": DeepSenoTheme.accentGreen
        case "video": DeepSenoTheme.accentBlue
        case "pdf", "docx", "text": DeepSenoTheme.accentAmber
        case "image": Color.purple
        default: DeepSenoTheme.textSecondary
        }
    }

    private func metaTag(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(DeepSenoTheme.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(DeepSenoTheme.bgTertiary.opacity(0.6))
        .clipShape(Capsule())
    }

    private func formatDate(_ isoString: String) -> String {
        let parts = isoString.prefix(10).split(separator: "-")
        guard parts.count == 3 else { return String(isoString.prefix(10)) }
        return "\(parts[1])/\(parts[2])"
    }
}
