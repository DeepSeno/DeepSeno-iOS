import SwiftUI
@preconcurrency import AVFoundation

struct MultiPhotoCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.i18n) private var i18n
    @State private var capturedPhotos: [CapturedPhoto] = []
    @State private var cameraManager = CameraManager()

    let onDone: ([URL]) -> Void

    var body: some View {
        ZStack {
            // Full-screen camera preview behind everything
            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            // Controls overlay
            VStack(spacing: 0) {
                // Header: Cancel | photo count | Done
                HStack {
                    Button(i18n.t.cancel) { dismiss() }
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.gray)
                    Spacer()
                    Text(capturedPhotos.isEmpty
                         ? i18n.t.camera
                         : "\(capturedPhotos.count) \(i18n.t.photoCount)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(i18n.t.done) {
                        onDone(capturedPhotos.map(\.url))
                        dismiss()
                    }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(capturedPhotos.isEmpty ? .gray : .white)
                    .disabled(capturedPhotos.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.6))

                Spacer()

                // Thumbnail strip (horizontal scroll, 60x60 thumbnails with x remove + index)
                if !capturedPhotos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(capturedPhotos.enumerated()), id: \.element.id) { index, photo in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: photo.thumbnail)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    // Remove button
                                    Button {
                                        capturedPhotos.remove(at: index)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white, .red)
                                    }
                                    .offset(x: 6, y: -6)

                                    // Index label
                                    Text("\(index + 1)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .background(.black.opacity(0.6))
                                        .clipShape(RoundedRectangle(cornerRadius: 2))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                        .padding(4)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 80)
                    .background(.black.opacity(0.8))
                }

                // Capture button (white ring 72px + white circle 56px)
                HStack {
                    Spacer()
                    Button {
                        cameraManager.capturePhoto { image in
                            if let photo = savePhoto(image) {
                                capturedPhotos.append(photo)
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                            Circle().fill(.white).frame(width: 56, height: 56)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 24)
                .background(.black.opacity(0.8))
            }
        }
        .onAppear { cameraManager.start() }
        .onDisappear { cameraManager.stop() }
        .statusBarHidden(true)
    }

    private func savePhoto(_ image: UIImage) -> CapturedPhoto? {
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
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return nil }
        let fileName = "deepseno-photo-\(Int(Date().timeIntervalSince1970))-\(capturedPhotos.count + 1).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
        let thumbSize = CGSize(width: 120, height: 120)
        let thumbRenderer = UIGraphicsImageRenderer(size: thumbSize)
        let thumbnail = thumbRenderer.image { _ in resized.draw(in: CGRect(origin: .zero, size: thumbSize)) }
        return CapturedPhoto(url: url, thumbnail: thumbnail)
    }
}

// MARK: - Data Types

struct CapturedPhoto: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: UIImage
}

// MARK: - Camera Manager

@Observable
@MainActor
class CameraManager: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let photoDelegate = PhotoCaptureDelegate()

    func start() {
        guard !session.isRunning else { return }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func capturePhoto(completion: @escaping @MainActor (UIImage) -> Void) {
        photoDelegate.completion = completion
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: photoDelegate)
    }
}

// MARK: - Photo Capture Delegate (separate class for Sendable compliance)

@MainActor
class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    var completion: (@MainActor (UIImage) -> Void)?

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        Task { @MainActor [weak self] in
            self?.completion?(image)
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Layer frame is updated in layoutSubviews
    }
}

class CameraPreviewUIView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
