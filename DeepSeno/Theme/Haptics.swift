import UIKit

/// Lightweight wrapper over UIImpactFeedbackGenerator / UINotificationFeedbackGenerator.
/// Cheap to call frequently — generators are created on demand and released immediately.
enum Haptics {
    static func light() { fire(.light) }
    static func medium() { fire(.medium) }
    static func heavy() { fire(.heavy) }
    static func success() { notify(.success) }
    static func warning() { notify(.warning) }

    private static func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred()
    }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }
}
