import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.i18n) private var i18n
    private var viewModel: SettingsViewModel { appState.settingsVM }
    @State private var bonjourBrowser = BonjourBrowser()
    /// Live transcription locale preference. Empty string = auto. @AppStorage
    /// makes the Picker re-render on change (UserDefaults alone wouldn't).
    @AppStorage("transcription_locale") private var transcriptionLocale: String = ""
    @AppStorage(TranscriptCorrector.correctionEnabledKey) private var correctionEnabled: Bool = true
    /// Persisted "allow public access" preference. Mirrored into the VM's
    /// transient `allowPublicAccess` while the manual-connect sheet is open.
    @AppStorage(SettingsViewModel.allowPublicAccessKey) private var allowPublicAccess: Bool = false

    /// Ambient glow tint reflects connection state — green when linked, a calm
    /// neutral while unpaired. Drives the radial wash behind the scroll content.
    private var glowColor: Color {
        appState.isConnected ? DeepSenoTheme.accentGreen : DeepSenoTheme.textTertiary
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return ScrollView {
            VStack(spacing: 14) {
                // HERO — connection beacon (dominant focal element)
                connectionHero
                    .revealOnAppear(delay: 0)

                // Discovered devices (only when not connected)
                if !appState.isConnected {
                    discoveredDevicesSection
                        .revealOnAppear(delay: 0.06)
                }

                // Upload Queue
                uploadQueueSection
                    .revealOnAppear(delay: 0.12)

                // Live transcription (language + AI polish, grouped)
                transcriptionSection
                    .revealOnAppear(delay: 0.18)

                // About footer
                aboutSection
                    .revealOnAppear(delay: 0.24)
            }
            .padding(16)
            .padding(.top, 4)
        }
        .background(ambientBackground)
        .navigationTitle(i18n.t.settings)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $viewModel.activeSheet) { sheet in
            switch sheet {
            case .pairing:
                PairingView()
            case .manualConnect:
                manualConnectSheet
            case .bonjourConnect:
                bonjourConnectSheet
            }
        }
        .onAppear {
            if !appState.isConnected {
                bonjourBrowser.startBrowsing()
            }
        }
        .onDisappear {
            bonjourBrowser.stopBrowsing()
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected {
                bonjourBrowser.stopBrowsing()
            } else {
                bonjourBrowser.startBrowsing()
            }
        }
    }

    // MARK: - Ambient Background

    /// Flat black base with a soft radial wash near the top, giving the page a
    /// focal atmosphere instead of dead-flat black. Tint animates with state.
    private var ambientBackground: some View {
        ZStack(alignment: .top) {
            DeepSenoTheme.bgPrimary
            RadialGradient(
                gradient: Gradient(colors: [glowColor.opacity(0.16), .clear]),
                center: .top,
                startRadius: 8,
                endRadius: 340
            )
            .frame(height: 380)
            .frame(maxWidth: .infinity, alignment: .top)
            .blur(radius: 24)
            .animation(.easeInOut(duration: 0.5), value: appState.isConnected)
        }
        .ignoresSafeArea()
    }

    // MARK: - Connection Hero

    private var connectionHero: some View {
        let connected = appState.isConnected
        return VStack(alignment: .leading, spacing: 16) {
            if connected {
                // No status label or beacon — connection state is shown by the
                // card's green border/glow plus the address and disconnect action.
                HStack(spacing: 12) {
                    if let host = appState.connectionHost, let port = appState.connectionPort {
                        // verbatim: avoid SwiftUI localizing the Int port into "18,526"
                        Text(verbatim: "\(host):\(port)")
                            .font(DeepSenoTheme.monoBodyFont)
                            .foregroundStyle(DeepSenoTheme.accentGreen)
                    }
                    Spacer(minLength: 0)
                    Button {
                        appState.disconnect()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 12))
                            Text(i18n.t.disconnect)
                                .font(DeepSenoTheme.captionFont)
                        }
                        .foregroundStyle(DeepSenoTheme.accentRed)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(DeepSenoTheme.accentRed.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 10) {
                    heroAction(icon: "qrcode", title: i18n.t.pairQR, filled: true) {
                        viewModel.activeSheet = .pairing
                    }
                    heroAction(icon: "keyboard", title: i18n.t.manualConnect, filled: false) {
                        viewModel.resetForm()
                        viewModel.activeSheet = .manualConnect
                    }
                }

                // 记得上次配对时,提供一个彻底清除的出口(否则「断开」只是暂时断开)。
                if appState.hasSavedPairing {
                    Button {
                        appState.forget()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text(i18n.t.forgetDevice)
                                .font(DeepSenoTheme.captionFont)
                        }
                        .foregroundStyle(DeepSenoTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(DeepSenoTheme.bgSecondary.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    LinearGradient(
                        colors: [
                            (connected ? DeepSenoTheme.accentGreen : DeepSenoTheme.textTertiary).opacity(0.5),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: connected ? DeepSenoTheme.accentGreen.opacity(0.18) : Color.black.opacity(0.25),
            radius: 22,
            y: 10
        )
        .animation(.easeInOut(duration: 0.35), value: connected)
    }

    private func heroAction(icon: String, title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(filled ? DeepSenoTheme.bgPrimary : DeepSenoTheme.accentGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(filled ? AnyShapeStyle(DeepSenoTheme.accentGradient)
                                 : AnyShapeStyle(DeepSenoTheme.accentGreen.opacity(0.12)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DeepSenoTheme.accentGreen.opacity(filled ? 0 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upload Queue Section

    private var uploadQueueSection: some View {
        let pending = appState.captureQueue.pendingCount
        let failed = appState.captureQueue.failedCount
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(i18n.t.uploadQueue)

            // One status line that adapts to queue health; whole row taps
            // through to the full queue detail.
            NavigationLink {
                QueueManagementView()
            } label: {
                HStack(spacing: 10) {
                    queueStatus(pending: pending, failed: failed)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(DeepSenoTheme.textSecondary.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Recovery actions appear only when there's something to recover.
            if failed > 0 {
                HStack(spacing: 8) {
                    Button {
                        appState.captureQueue.retryAll()
                        if let api = appState.apiClient {
                            Task {
                                await appState.captureQueue.processQueue(apiClient: api)
                            }
                        }
                    } label: {
                        queueActionChip(icon: "arrow.clockwise", title: i18n.t.retryAll, color: DeepSenoTheme.accentGreen)
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.captureQueue.clearAll()
                    } label: {
                        queueActionChip(icon: "trash", title: i18n.t.clear, color: DeepSenoTheme.accentRed)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
        }
        .cardStyle()
    }

    /// State-dependent status line: green when empty, amber while uploading,
    /// red when something failed.
    @ViewBuilder
    private func queueStatus(pending: Int, failed: Int) -> some View {
        if failed > 0 {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.accentRed)
                HStack(spacing: 4) {
                    Text(verbatim: "\(failed)")
                        .fontWeight(.semibold)
                        .foregroundStyle(DeepSenoTheme.accentRed)
                    Text(i18n.t.failed)
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    if pending > 0 {
                        Text(verbatim: "· \(pending)")
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                        Text(i18n.t.pending)
                            .foregroundStyle(DeepSenoTheme.textTertiary)
                    }
                }
                .font(.system(.subheadline, design: .default))
            }
        } else if pending > 0 {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.accentAmber)
                HStack(spacing: 4) {
                    Text(verbatim: "\(pending)")
                        .fontWeight(.semibold)
                        .foregroundStyle(DeepSenoTheme.accentAmber)
                    Text(i18n.t.pending)
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                .font(.system(.subheadline, design: .default))
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                Text(i18n.t.queueEmpty)
                    .font(.system(.subheadline, design: .default))
                    .foregroundStyle(DeepSenoTheme.textSecondary)
            }
        }
    }

    /// Compact icon+label action chip used for queue recovery actions.
    private func queueActionChip(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(DeepSenoTheme.captionFont)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    // MARK: - Transcription Section (language + AI polish, grouped)

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Language
            VStack(alignment: .leading, spacing: 10) {
                rowLabel(icon: "waveform.badge.mic", title: i18n.t.liveTranscriptionLanguageTitle)
                Picker("", selection: Binding(
                    get: { TranscriptLang(rawStore: transcriptionLocale) },
                    set: { transcriptionLocale = $0.rawStore }
                )) {
                    Text(i18n.t.liveTranscriptionLanguageAuto).tag(TranscriptLang.auto)
                    Text(i18n.t.liveTranscriptionLanguageChinese).tag(TranscriptLang.chinese)
                    Text(i18n.t.liveTranscriptionLanguageEnglish).tag(TranscriptLang.english)
                    Text(i18n.t.liveTranscriptionLanguageMultilingual).tag(TranscriptLang.multilingual)
                }
                .pickerStyle(.segmented)
                Text(i18n.t.liveTranscriptionLanguageHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
            }

            // Hairline divider between grouped controls
            Rectangle()
                .fill(DeepSenoTheme.glassBorder)
                .frame(height: 1)
                .padding(.vertical, 2)

            // AI polish
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    rowLabel(icon: "sparkles", title: i18n.t.transcriptionCorrectionTitle)
                    Spacer()
                    Toggle("", isOn: $correctionEnabled)
                        .labelsHidden()
                        .tint(DeepSenoTheme.accentGreen)
                }
                Text(i18n.t.transcriptionCorrectionHint)
                    .font(.system(size: 11))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .cardStyle()
    }

    private enum TranscriptLang: String, Hashable, CaseIterable {
        case auto, chinese, english, multilingual

        init(rawStore: String) {
            switch rawStore {
            case "zh-Hans": self = .chinese
            case "en-US": self = .english
            case "multilingual": self = .multilingual
            default: self = .auto
            }
        }

        var rawStore: String {
            switch self {
            case .auto: return ""
            case .chinese: return "zh-Hans"
            case .english: return "en-US"
            case .multilingual: return "multilingual"
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return VStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(DeepSenoTheme.glassBorderLight, lineWidth: 1)
                )

            Text("DeepSeno")
                .font(DeepSenoTheme.headlineFont)
                .foregroundStyle(DeepSenoTheme.textPrimary)

            Text("v\(version) (\(build))")
                .font(DeepSenoTheme.monoFont)
                .foregroundStyle(DeepSenoTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    // MARK: - Discovered Devices

    private var discoveredDevicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(i18n.t.discoveredDevices)
                Spacer()
                // 只在「还没发现到任何设备」时转圈;发现到后停掉(浏览仍在后台继续)。
                if bonjourBrowser.isSearching && bonjourBrowser.discoveredDevices.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DeepSenoTheme.textSecondary)
                }
            }

            if bonjourBrowser.discoveredDevices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    Text(i18n.t.searchingDevices)
                        .font(DeepSenoTheme.captionFont)
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(bonjourBrowser.discoveredDevices) { device in
                    Button {
                        if appState.hasSavedPairing {
                            // 记得配对 → 解析到地址后用记住的 token 一键直连,不弹手动页
                            bonjourBrowser.resolve(device) { host, port in
                                Task { @MainActor in
                                    appState.connectWithSavedToken(host: host, port: port)
                                }
                            }
                        } else {
                            // 从未配对 → 弹手动连接页,要求填 token
                            viewModel.selectedBonjourDevice = device.name
                            viewModel.activeSheet = .bonjourConnect
                            bonjourBrowser.resolve(device) { host, port in
                                Task { @MainActor in
                                    viewModel.manualHost = host
                                    viewModel.manualPort = "\(port)"
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 14))
                                .foregroundStyle(DeepSenoTheme.accentGreen)
                                .frame(width: 28, height: 28)
                                .background(DeepSenoTheme.accentGreen.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text(device.name)
                                .font(DeepSenoTheme.bodyFont)
                                .foregroundStyle(DeepSenoTheme.textPrimary)

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(DeepSenoTheme.textSecondary.opacity(0.5))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Bonjour Connect Sheet

    private var bonjourConnectSheet: some View {
        @Bindable var viewModel = viewModel
        return NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 20))
                        .foregroundStyle(DeepSenoTheme.accentGreen)
                    Text(viewModel.selectedBonjourDevice ?? "Device")
                        .font(DeepSenoTheme.headlineFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                }
                .padding(.bottom, 8)

                if !viewModel.manualHost.isEmpty {
                    HStack {
                        Text(i18n.t.addressLabel)
                            .font(DeepSenoTheme.captionFont)
                            .foregroundStyle(DeepSenoTheme.textSecondary)
                        Text("\(viewModel.manualHost):\(viewModel.manualPort)")
                            .font(DeepSenoTheme.captionFont)
                            .foregroundStyle(DeepSenoTheme.textPrimary)
                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelToken)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField(i18n.t.pasteTokenPlaceholder, text: $viewModel.manualToken)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if let error = viewModel.connectError {
                    Text(error)
                        .font(DeepSenoTheme.captionFont)
                        .foregroundStyle(DeepSenoTheme.accentRed)
                }

                Button {
                    viewModel.connectFromBonjour(appState: appState)
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

                Spacer()
            }
            .padding(16)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.connectDeviceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t.cancel) {
                        viewModel.activeSheet = nil
                        viewModel.resetForm()
                    }
                    .foregroundStyle(DeepSenoTheme.textSecondary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Manual Connect Sheet

    private var manualConnectSheet: some View {
        @Bindable var viewModel = viewModel
        return NavigationStack {
            VStack(spacing: 16) {
                // Paste JSON button
                Button {
                    viewModel.pasteConnectionJSON()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13))
                        Text(i18n.t.pasteJSON)
                            .font(DeepSenoTheme.captionFont)
                    }
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(DeepSenoTheme.accentGreen.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelHost)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("192.168.1.x", text: $viewModel.manualHost)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelPort)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("18526", text: $viewModel.manualPort)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .keyboardType(.numberPad)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelToken)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("Auth token", text: $viewModel.manualToken)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                publicAccessFields

                if let error = viewModel.connectError {
                    Text(error)
                        .font(DeepSenoTheme.captionFont)
                        .foregroundStyle(DeepSenoTheme.accentRed)
                }

                Button {
                    viewModel.manualConnect(appState: appState)
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

                Spacer()
            }
            .padding(16)
            .background(DeepSenoTheme.bgPrimary)
            .navigationTitle(i18n.t.manualConnect)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.t.cancel) { viewModel.activeSheet = nil }
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                }
            }
            .onAppear {
                // Hydrate the form toggle from persisted preference (unless a pasted
                // QR already forced it on by populating manualPublicHost).
                if !viewModel.allowPublicAccess { viewModel.allowPublicAccess = allowPublicAccess }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Public Access Fields (Manual Connect Sheet)

    private var publicAccessFields: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(DeepSenoTheme.accentGreen)
                Text(i18n.t.publicAccessTitle)
                    .font(DeepSenoTheme.bodyFont)
                    .foregroundStyle(DeepSenoTheme.textPrimary)
                Spacer()
                Toggle("", isOn: $viewModel.allowPublicAccess)
                    .labelsHidden()
                    .onChange(of: viewModel.allowPublicAccess) { _, newValue in
                        allowPublicAccess = newValue // persist
                    }
            }

            if viewModel.allowPublicAccess {
                Text(i18n.t.publicAccessHint)
                    .font(.system(size: 11))
                    .foregroundStyle(DeepSenoTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelPublicHost)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("vps.example.com", text: $viewModel.manualPublicHost)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelPublicPort)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("8526", text: $viewModel.manualPublicPort)
                        .font(DeepSenoTheme.bodyFont)
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .keyboardType(.numberPad)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(i18n.t.formLabelFingerprint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textSecondary)
                    TextField("AA:BB:CC:…", text: $viewModel.manualFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DeepSenoTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(DeepSenoTheme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Section header: mono uppercase label with a leading emerald accent bar.
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(DeepSenoTheme.accentGreen)
                .frame(width: 3, height: 13)
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .tracking(1.0)
                .foregroundStyle(DeepSenoTheme.textSecondary)
        }
    }

    /// Inline label for a control row: small green icon + title.
    private func rowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DeepSenoTheme.accentGreen)
            Text(title)
                .font(DeepSenoTheme.bodyFont)
                .foregroundStyle(DeepSenoTheme.textPrimary)
        }
    }

}

// MARK: - Reveal On Appear

/// Staggered entrance: fade + slide-up driven by a per-card delay.
private struct RevealOnAppear: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(delay)) {
                    shown = true
                }
            }
    }
}

private extension View {
    func revealOnAppear(delay: Double) -> some View {
        modifier(RevealOnAppear(delay: delay))
    }
}
