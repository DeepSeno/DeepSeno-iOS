import UIKit

/// Lightweight wrapper over UIImpactFeedbackGenerator / UINotificationFeedbackGenerator.
/// Cheap to call frequently — generators are created on demand and released immediately.
enum Haptics {
    static func light() { Task { @MainActor in fire(.light) } }
    static func medium() { Task { @MainActor in fire(.medium) } }
    static func heavy() { Task { @MainActor in fire(.heavy) } }
    static func success() { Task { @MainActor in notify(.success) } }
    static func warning() { Task { @MainActor in notify(.warning) } }

    @MainActor
    private static func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }

    @MainActor
    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }
}
