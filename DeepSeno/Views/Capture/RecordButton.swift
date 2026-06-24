import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.3

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow (always, stronger when recording)
                Circle()
                    .fill(DeepSenoTheme.accentRed.opacity(isRecording ? 0.08 : 0.03))
                    .frame(width: 120, height: 120)

                // Pulse rings (recording only)
                if isRecording {
                    Circle()
                        .stroke(DeepSenoTheme.accentRed.opacity(pulseOpacity), lineWidth: 1.5)
                        .frame(width: 110, height: 110)
                        .scaleEffect(pulseScale)

                    Circle()
                        .fill(DeepSenoTheme.accentRed.opacity(pulseOpacity * 0.5))
                        .frame(width: 110, height: 110)
                        .scaleEffect(pulseScale * 0.95)
                }

                // Outer ring — subtle gradient
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [DeepSenoTheme.accentRed, DeepSenoTheme.accentRed.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 100, height: 100)

                // Inner shape
                if isRecording {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DeepSenoTheme.accentRed)
                        .frame(width: 36, height: 36)
                } else {
                    Circle()
                        .fill(DeepSenoTheme.accentRed)
                        .frame(width: 80, height: 80)
                }
            }
            .shadow(color: DeepSenoTheme.accentRed.opacity(isRecording ? 0.25 : 0.1), radius: 20, y: 4)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isRecording)
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, recording in
            if recording {
                startPulse()
            } else {
                pulseScale = 1.0
                pulseOpacity = 0.3
            }
        }
    }

    private func startPulse() {
        withAnimation(
            .easeOut(duration: 1.5)
            .repeatForever(autoreverses: false)
        ) {
            pulseScale = 1.4
            pulseOpacity = 0
        }
    }
}
