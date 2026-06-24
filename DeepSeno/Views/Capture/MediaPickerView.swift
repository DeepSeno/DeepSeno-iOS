import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MediaPickerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case images     // multi-select images
        case video      // single video
    }

    let mode: Mode
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        switch mode {
        case .images:
            config.filter = .images
            config.selectionLimit = 0  // unlimited
        case .video:
            config.filter = .videos
            config.selectionLimit = 1
        }
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPickerView
        init(_ parent: MediaPickerView) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.dismiss()
                return
            }

            let onPick = parent.onPick
            let dismiss = parent.dismiss

            Task {
                var urls: [URL] = []
                for result in results {
                    if let url = await self.loadFile(from: result) {
                        urls.append(url)
                    }
                }
                await MainActor.run {
                    if !urls.isEmpty { onPick(urls) }
                    dismiss()
                }
            }
        }

        private func loadFile(from result: PHPickerResult) async -> URL? {
            let provider = result.itemProvider

            // Try video
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                return await withCheckedContinuation { cont in
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        guard let url else { cont.resume(returning: nil); return }
                        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("deepseno-video-\(Int(Date().timeIntervalSince1970)).\(ext)")
                        try? FileManager.default.removeItem(at: dest)
                        do {
                            try FileManager.default.copyItem(at: url, to: dest)
                            cont.resume(returning: dest)
                        } catch {
                            print("[MediaPicker] video copy failed: \(error)")
                            cont.resume(returning: nil)
                        }
                    }
                }
            }

            // Try image
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return await withCheckedContinuation { cont in
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        guard let image = object as? UIImage else { cont.resume(returning: nil); return }
                        // Resize & compress
                        let maxWidth: CGFloat = 2048
                        let resized: UIImage
                        if image.size.width > maxWidth {
                            let scale = maxWidth / image.size.width
                            let newSize = CGSize(width: maxWidth, height: image.size.height * scale)
                            let renderer = UIGraphicsImageRenderer(size: newSize)
                            resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
                        } else {
                            resized = image
                        }
                        guard let data = resized.jpegData(compressionQuality: 0.8) else {
                            cont.resume(returning: nil); return
                        }
                        let fileName = "deepseno-photo-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999)).jpg"
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                        do {
                            try data.write(to: dest)
                            cont.resume(returning: dest)
                        } catch {
                            print("[MediaPicker] photo write failed: \(error)")
                            cont.resume(returning: nil)
                        }
                    }
                }
            }

            return nil
        }
    }
}
