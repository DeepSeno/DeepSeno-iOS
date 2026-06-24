import SwiftUI

struct TextMemoSheet: View {
    @Environment(\.i18n) private var i18n
    @Bindable var viewModel: CaptureViewModel
    let queue: CaptureQueue

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $viewModel.memoText)
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(DeepSenoTheme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .focused($isFocused)
                    .frame(minHeight: 150)

                HStack(spacing: 12) {
                    Button {
                        viewModel.showTextMemo = false
                        viewModel.memoText = ""
                    } label: {
                        Text(i18n.t.cancel)
                            .font(DeepSenoTheme.bodyFont)
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(DeepSenoTheme.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        viewModel.submitMemo(queue: queue)
                    } label: {
                        Text(i18n.t.send)
                            .font(DeepSenoTheme.bodyFont)
                            .fontWeight(.semibold)
                            .foregroundStyle(DeepSenoTheme.bgPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                viewModel.memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? DeepSenoTheme.accentGreen.opacity(0.4)
                                    : DeepSenoTheme.accentGreen
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(viewModel.memoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.textMemo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
