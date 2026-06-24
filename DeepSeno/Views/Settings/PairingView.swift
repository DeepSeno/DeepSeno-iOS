import SwiftUI
@preconcurrency import AVFoundation

struct PairingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    @Environment(\.dismiss) private var dismiss

    @State private var scannedCode: String?
    @State private var errorMessage: String?
    @State private var showManualInput = false
    @State private var manualInput = ""
    @State private var cameraPermission: AVAuthorizationStatus = .notDetermined

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if showManualInput {
                    manualInputView
                } else {
                    cameraView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.pairViaQR)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t.cancel) { dismiss() }
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(showManualInput ? i18n.t.camera : i18n.t.manualLabel) {
                        showManualInput.toggle()
                    }
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                }
            }
            .onAppear {
                cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    // MARK: - Camera View

    private var cameraView: some View {
        VStack(spacing: 16) {
            Text(i18n.t.scanQRHint)
                .font(DeepSenoTheme.captionFont)
                .foregroundStyle(DeepSenoTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 16)

            if cameraPermission == .authorized || cameraPermission == .notDetermined {
                QRScannerView { code in
                    handleQRCode(code)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DeepSenoTheme.bgTertiary, lineWidth: 1)
                )
                .padding(.horizontal, 32)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(DeepSenoTheme.textSecondary)

                    Text(i18n.t.cameraRequired)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)

                    Text(i18n.t.cameraRequiredSubtitle)
                        .font(DeepSenoTheme.captionFont)
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    Button(i18n.t.useManualInput) {
                        showManualInput = true
                    }
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                    .padding(.top, 8)
                }
                .padding(40)
            }

            if let error = errorMessage {
                Text(error)
                    .font(DeepSenoTheme.captionFont)
                    .foregroundStyle(DeepSenoTheme.accentRed)
                    .padding(.horizontal, 16)
            }

            Spacer()
        }
    }

    // MARK: - Manual Input

    private var manualInputView: some View {
        VStack(spacing: 16) {
            Text(i18n.t.pasteQRHint)
                .font(DeepSenoTheme.captionFont)
                .foregroundStyle(DeepSenoTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 16)

            TextEditor(text: $manualInput)
                .font(DeepSenoTheme.bodyFont)
                .foregroundStyle(DeepSenoTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(DeepSenoTheme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(height: 120)
                .padding(.horizontal, 16)

            Button {
                handleQRCode(manualInput)
            } label: {
                Text(i18n.t.connect)
                    .font(DeepSenoTheme.bodyFont)
                    .fontWeight(.semibold)
                    .foregroundStyle(DeepSenoTheme.bgPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DeepSenoTheme.accentGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)

            if let error = errorMessage {
                Text(error)
                    .font(DeepSenoTheme.captionFont)
                    .foregroundStyle(DeepSenoTheme.accentRed)
            }

            Spacer()
        }
    }

    // MARK: - Handler

    private func handleQRCode(_ code: String) {
        let success = appState.connectFromQR(jsonString: code)
        if success {
            dismiss()
        } else {
            errorMessage = i18n.t.invalidQR
        }
    }
}

// MARK: - QRScannerView

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: @MainActor @Sendable (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController {
    var onCodeScanned: (@MainActor @Sendable (String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private let metadataDelegate = QRMetadataDelegate()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = captureSession
        if session != nil {
            DispatchQueue.global(qos: .userInitiated).async {
                session?.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        if session != nil {
            DispatchQueue.global(qos: .userInitiated).async {
                session?.stopRunning()
            }
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            metadataDelegate.onQRCode = { [weak self] value in
                guard let self, !self.hasScanned else { return }
                self.hasScanned = true
                self.onCodeScanned?(value)
            }
            output.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }
}

// Separate delegate class to avoid Sendable issues with UIViewController
@MainActor
class QRMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    var onQRCode: (@MainActor (String) -> Void)?

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // Delegate is called on main queue, extract string value here (nonisolated)
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        let scannedValue = value
        Task { @MainActor [weak self] in
            self?.onQRCode?(scannedValue)
        }
    }
}
