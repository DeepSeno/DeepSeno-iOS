import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            close()
            return
        }

        let group = DispatchGroup()

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                group.enter()
                handleAttachment(attachment) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.close()
        }
    }

    private func handleAttachment(_ attachment: NSItemProvider, completion: @escaping @Sendable () -> Void) {
        // Try file types first: audio, video, PDF, image
        let fileTypes: [UTType] = [.audio, .movie, .pdf, .image]

        for type in fileTypes {
            if attachment.hasItemConformingToTypeIdentifier(type.identifier) {
                attachment.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    if let url, error == nil {
                        Self.saveToSharedContainer(url: url)
                    }
                    completion()
                }
                return
            }
        }

        // Try plain text
        if attachment.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            attachment.loadItem(forTypeIdentifier: UTType.text.identifier) { text, _ in
                if let text = text as? String {
                    Self.saveTextToSharedContainer(text: text)
                }
                completion()
            }
            return
        }

        // Try URL (shared links)
        if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            attachment.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let url = item as? URL {
                    Self.saveTextToSharedContainer(text: url.absoluteString)
                }
                completion()
            }
            return
        }

        completion()
    }

    private nonisolated static func saveToSharedContainer(url: URL) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.enmooy.deepseno"
        ) else { return }

        let sharedDir = containerURL.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let destURL = sharedDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: url, to: destURL)

        // Write a marker file so main app knows there are new shared files
        let marker = sharedDir.appendingPathComponent(".new-\(UUID().uuidString)")
        try? destURL.path.write(to: marker, atomically: true, encoding: .utf8)
    }

    private nonisolated static func saveTextToSharedContainer(text: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.enmooy.deepseno"
        ) else { return }

        let sharedDir = containerURL.appendingPathComponent("SharedFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let fileName = "shared-text-\(Int(Date().timeIntervalSince1970)).txt"
        let destURL = sharedDir.appendingPathComponent(fileName)
        try? text.write(to: destURL, atomically: true, encoding: .utf8)

        let marker = sharedDir.appendingPathComponent(".new-\(UUID().uuidString)")
        try? destURL.path.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
