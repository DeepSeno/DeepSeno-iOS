import Foundation
import AVFoundation

/// Thread-safe state shared between main thread and audio render thread.
private final class RecorderShared: @unchecked Sendable {
    private let lock = NSLock()
    private var _isPaused = false
    private var _audioLevel: Float = 0
    private var _audioFile: AVAudioFile?
    private var _onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var _writeFailed = false

    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPaused }
        set { lock.lock(); _isPaused = newValue; lock.unlock() }
    }

    var audioLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _audioLevel }
        set { lock.lock(); _audioLevel = newValue; lock.unlock() }
    }

    func setFile(_ file: AVAudioFile?) {
        lock.lock(); _audioFile = file; lock.unlock()
    }

    func writeToFile(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let file = _audioFile; let alreadyFailed = _writeFailed; lock.unlock()
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            if !alreadyFailed {
                // Log only once per recording to avoid spamming the render thread
                print("[AudioRecorder] file write failed: \(error)")
                lock.lock(); _writeFailed = true; lock.unlock()
            }
        }
    }

    var writeFailed: Bool {
        lock.lock(); defer { lock.unlock() }; return _writeFailed
    }

    func setOnAudioBuffer(_ cb: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); _onAudioBuffer = cb; lock.unlock()
    }

    func forwardBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let cb = _onAudioBuffer; lock.unlock()
        cb?(buffer)
    }

    func reset() {
        lock.lock()
        _isPaused = false
        _audioLevel = 0
        _audioFile = nil
        _onAudioBuffer = nil
        _writeFailed = false
        lock.unlock()
    }
}

/// Single AVAudioEngine pipeline: records to file, computes audio level, and
/// forwards PCM buffers to LiveTranscriber for speech recognition.
/// No @MainActor — SwiftUI accesses @Observable from background threads.
@Observable
class AudioRecorder: NSObject, @unchecked Sendable {
    var isRecording = false
    var isPaused = false
    var wasInterrupted = false
    var duration: TimeInterval = 0
    var currentFileURL: URL?
    var audioLevel: Float = 0
    var bookmarks: [TimeInterval] = []

    private let shared = RecorderShared()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var timer: Timer?
    private var startTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// Called by LiveTranscriber to receive 16kHz mono Float32 PCM buffers
    func setOnAudioBuffer(_ cb: ((AVAudioPCMBuffer) -> Void)?) {
        shared.setOnAudioBuffer(cb)
    }

    /// Whether any audio frame write failed during the current recording.
    /// Check before calling stopRecording() / after stop, file may be truncated.
    var didWriteFail: Bool { shared.writeFailed }

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let fileName = "deepseno-\(Int(Date().timeIntervalSince1970)).wav"
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "AudioRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot find Application Support directory"])
        }
        let recordingsDir = appSupportDir.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let fileURL = recordingsDir.appendingPathComponent(fileName)

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create target format"])
        }

        // WAV output (LinearPCM) — universally supported, ~1.9 MB/min at 16kHz mono 16-bit
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        shared.setFile(audioFile)
        shared.isPaused = false

        // Setup engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid hardware format"])
        }

        // Converter: hardware format → 16kHz mono
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }
        self.converter = conv

        let sharedRef = shared
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
            // Convert to 16kHz mono
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0,
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)
            else { return }

            var error: NSError?
            var consumed = false
            conv.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, outputBuffer.frameLength > 0 else { return }

            // 1. Write to M4A file (skip if paused)
            if !sharedRef.isPaused {
                sharedRef.writeToFile(outputBuffer)
            }

            // 2. Compute audio level
            if let channelData = outputBuffer.floatChannelData?[0] {
                let count = Int(outputBuffer.frameLength)
                var sum: Float = 0
                for i in 0..<count { sum += channelData[i] * channelData[i] }
                let rms = sqrtf(sum / Float(max(count, 1)))
                let db = 20 * log10f(max(rms, 1e-6))
                sharedRef.audioLevel = max(0, min(1, (db + 60) / 60))
            }

            // 3. Forward to LiveTranscriber for speech recognition
            sharedRef.forwardBuffer(outputBuffer)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine

        currentFileURL = fileURL
        isRecording = true
        isPaused = false
        wasInterrupted = false
        duration = 0
        pausedDuration = 0
        bookmarks = []
        startTime = Date()

        setupObservers()
        startTimer()
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        shared.isPaused = true
        timer?.invalidate()
        timer = nil
        isPaused = true
        pausedDuration = duration
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        shared.isPaused = false
        isPaused = false
        startTime = Date()
        startTimer()
    }

    func stopRecording() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        shared.reset()

        timer?.invalidate()
        timer = nil
        isRecording = false
        isPaused = false
        wasInterrupted = false
        audioLevel = 0

        cleanupObservers()

        let url = currentFileURL

        // Diagnostic: log written file size so we can tell whether the engine
        // actually delivered audio (problem with the desktop seeing an empty
        // recording was traced to this in v1.4.x).
        if let url {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("[AudioRecorder] stop: file=\(url.lastPathComponent) bytes=\(size)")
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        return url
    }

    /// Refresh duration display when returning from background
    func refreshDuration() {
        guard isRecording, !isPaused, let start = startTime else { return }
        duration = pausedDuration + Date().timeIntervalSince(start)
    }

    func addBookmark() {
        guard isRecording else { return }
        bookmarks.append(duration)
    }

    var formattedDuration: String {
        let total = Int(duration)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Interruption & Route Change Handling

    private func setupObservers() {
        let nc = NotificationCenter.default

        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func cleanupObservers() {
        let nc = NotificationCenter.default
        if let o = interruptionObserver { nc.removeObserver(o); interruptionObserver = nil }
        if let o = routeChangeObserver { nc.removeObserver(o); routeChangeObserver = nil }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // Phone call, Siri, or alarm — engine is auto-paused by system
            guard isRecording, !isPaused else { return }
            shared.isPaused = true
            timer?.invalidate()
            timer = nil
            pausedDuration = duration
            isPaused = true
            wasInterrupted = true
            print("[AudioRecorder] interruption began")

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                // Safe to resume — reactivate session and restart engine
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try engine?.start()
                    shared.isPaused = false
                    isPaused = false
                    wasInterrupted = false
                    startTime = Date()
                    startTimer()
                    print("[AudioRecorder] interruption ended, auto-resumed")
                } catch {
                    print("[AudioRecorder] failed to resume after interruption: \(error)")
                }
            } else {
                print("[AudioRecorder] interruption ended, waiting for manual resume")
            }

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        if reason == .oldDeviceUnavailable {
            let route = AVAudioSession.sharedInstance().currentRoute
            let output = route.outputs.first?.portName ?? "unknown"
            print("[AudioRecorder] route change: old device unavailable, now using: \(output)")
        }
    }

    // MARK: - Timer

    private func startTimer() {
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.isRecording, !self.isPaused, let start = self.startTime else { return }
            self.duration = self.pausedDuration + Date().timeIntervalSince(start)
            self.audioLevel = self.shared.audioLevel
        }
    }
}
