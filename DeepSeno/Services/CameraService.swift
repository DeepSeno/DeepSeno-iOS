import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (URL) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                let fileName = "deepseno-photo-\(Int(Date().timeIntervalSince1970)).jpg"
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                if let data = image.jpegData(compressionQuality: 0.8) {
                    do {
                        try data.write(to: tempURL)
                        parent.onCapture(tempURL)
                    } catch {
                        print("[CameraService] photo write failed: \(error)")
                    }
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Video Capture View

struct VideoCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (URL) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.videoMaximumDuration = 180  // 3 minutes
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> VideoCoordinator { VideoCoordinator(self) }

    class VideoCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoCaptureView
        init(_ parent: VideoCaptureView) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                let fileName = "deepseno-video-\(Int(Date().timeIntervalSince1970)).\(ext)"
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    parent.onCapture(dest)
                } catch {
                    print("[CameraService] video copy failed: \(error)")
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
