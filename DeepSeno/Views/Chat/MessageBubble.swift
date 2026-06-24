import SwiftUI

struct MessageBubble: View {
    @Environment(\.i18n) private var i18n
    let message: DisplayMessage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser { Spacer(minLength: 48) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    if message.content.isEmpty && message.isStreaming {
                        typingIndicator
                    } else if message.isStreaming {
                        Text(message.content + " \u{258C}")
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                            .lineSpacing(3)
                    } else if message.isUser {
                        Text(message.content)
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                            .lineSpacing(3)
                    } else {
                        // AI response: block-level markdown
                        MarkdownContentView(content: message.content)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(bubbleShape)

                if !message.sources.isEmpty {
                    sourcesView
                }
            }

            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.isUser {
            LinearGradient(
                colors: [DeepSenoTheme.accentGreen.opacity(0.14), DeepSenoTheme.accentGreen.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            DeepSenoTheme.bgSecondary.opacity(0.85)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(DeepSenoTheme.glassBorder, lineWidth: 1)
                )
        }
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: 14,
            bottomLeadingRadius: message.isUser ? 14 : 4,
            bottomTrailingRadius: message.isUser ? 4 : 14,
            topTrailingRadius: 14
        )
    }

    private var typingIndicator: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(DeepSenoTheme.textSecondary)
                    .frame(width: 5, height: 5)
                    .opacity(0.5)
            }
        }
        .padding(.vertical, 6)
    }

    private var sourcesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(i18n.t.sourcesLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DeepSenoTheme.textTertiary)
                .tracking(0.5)

            // Deduplicate and limit to 3 sources, hide meaningless 00:00 times
            let uniqueSources = deduplicatedSources(max: 3)
            ForEach(Array(uniqueSources.enumerated()), id: \.offset) { _, source in
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 8))
                        .foregroundStyle(DeepSenoTheme.accentGreen)

                    if let speaker = source.speaker {
                        Text(speaker)
                            .font(.system(size: 10))
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                    }

                    // Only show time if it's meaningful (not 00:00)
                    if let time = source.time, !time.contains("00:00") {
                        Text(time)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    }
                }
            }

            if message.sources.count > 3 {
                Text("+\(message.sources.count - 3)")
                    .font(.system(size: 10))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DeepSenoTheme.bgSecondary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func deduplicatedSources(max limit: Int) -> [StreamingMessage.Source] {
        var seen = Set<String>()
        var result: [StreamingMessage.Source] = []
        for source in message.sources {
            let key = (source.speaker ?? "") + (source.time ?? "")
            if seen.insert(key).inserted {
                result.append(source)
                if result.count >= limit { break }
            }
        }
        return result
    }
}

// MARK: - Markdown Content View

/// Renders block-level Markdown: headers (###), bullet lists (*), bold (**), inline code (`)
private struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    Text(inlineMarkdown(text))
                        .font(.system(size: level <= 2 ? 16 : 15, weight: .bold))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                            .frame(width: 10)
                        Text(inlineMarkdown(text))
                            .font(.system(size: 14))
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                            .lineSpacing(3)
                    }
                case .indentedBullet(let text):
                    HStack(alignment: .top, spacing: 8) {
                        Text("◦")
                            .font(.system(size: 12))
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                            .frame(width: 10)
                        Text(inlineMarkdown(text))
                            .font(.system(size: 13))
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                            .lineSpacing(3)
                    }
                    .padding(.leading, 16)
                case .paragraph(let text):
                    Text(inlineMarkdown(text))
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .lineSpacing(3)
                case .empty:
                    Spacer().frame(height: 2)
                }
            }
        }
    }

    private enum Block {
        case heading(String, Int)
        case bullet(String)
        case indentedBullet(String)
        case paragraph(String)
        case empty
    }

    private func parseBlocks() -> [Block] {
        let lines = content.components(separatedBy: "\n")
        var blocks: [Block] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                blocks.append(.empty)
            } else if trimmed.hasPrefix("### ") {
                blocks.append(.heading(String(trimmed.dropFirst(4)), 3))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.heading(String(trimmed.dropFirst(3)), 2))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.heading(String(trimmed.dropFirst(2)), 1))
            } else if line.hasPrefix("    * ") || line.hasPrefix("    - ") || line.hasPrefix("\t* ") || line.hasPrefix("\t- ") {
                let text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                blocks.append(.indentedBullet(text))
            } else if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                let text = String(trimmed.dropFirst(2))
                blocks.append(.bullet(text))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }
        return blocks
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        if let result = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return result
        }
        return AttributedString(text)
    }
}
