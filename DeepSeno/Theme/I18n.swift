import SwiftUI

// MARK: - Language

enum AppLanguage: String, CaseIterable {
    case en, zh

    var displayName: String {
        switch self {
        case .en: "English"
        case .zh: "中文"
        }
    }

    static var current: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }

    /// Locale to feed into DateFormatter / DatePicker so dates render in the
    /// app's chosen language. Use `Locale(identifier: "zh_Hans")` for Chinese
    /// (gives "2026年5月16日"), `en_US` for English ("May 16, 2026").
    var locale: Locale {
        switch self {
        case .zh: return Locale(identifier: "zh_Hans")
        case .en: return Locale(identifier: "en_US")
        }
    }
}

// MARK: - Strings

@Observable
final class I18nManager: @unchecked Sendable {
    var lang: AppLanguage

    init() {
        lang = AppLanguage.current
    }

    var t: Strings { lang == .zh ? .zh : .en }
}

// MARK: - Environment Key

private struct I18nManagerKey: EnvironmentKey {
    static let defaultValue = I18nManager()
}

extension EnvironmentValues {
    var i18n: I18nManager {
        get { self[I18nManagerKey.self] }
        set { self[I18nManagerKey.self] = newValue }
    }
}

struct Strings {
    // Tabs
    let tabCapture: String
    let tabSources: String
    let tabAI: String
    let tabBriefing: String
    let tabSettings: String

    // Capture
    let camera: String
    let memo: String
    let importFile: String
    let pending: String
    let failed: String
    let textMemo: String
    let cancel: String
    let send: String

    // Media capture
    let chooseImages: String
    let recordVideo: String
    let chooseVideo: String
    let photoCount: String
    let videoLimit: String
    let capture: String

    // Sources
    let sources: String
    let searchPlaceholder: String
    let filterAll: String
    let filterVoice: String
    let filterVideo: String
    let filterDocument: String
    let filterImage: String
    let filterText: String
    let noSources: String
    let noSourcesSubtitle: String
    let noResults: String
    let noResultsSubtitle: String
    let summary: String
    let extractedItems: String
    let transcript: String
    let notConnected: String

    // Chat
    let aiAssistant: String
    let askAnything: String
    let askPlaceholder: String
    let suggestToday: String
    let suggestMeetings: String
    let suggestTasks: String
    let suggestPeople: String
    let suggestDecisions: String
    let suggestSearch: String
    let newSession: String
    let sessions: String
    let done: String
    let listening: String
    let speakNow: String
    let sourcesLabel: String

    // Briefing
    let briefing: String
    let loading: String
    let summaryHeader: String
    let todosHeader: String
    let extractedHeader: String
    let noBriefing: String
    let noBriefingSubtitle: String
    let weeklySummary: String
    let noSummary: String
    let noWeeklySummary: String
    let noWeeklySummarySubtitle: String
    let daily: String
    let weekly: String

    // Settings
    let settings: String
    let connection: String
    let connected: String
    let disconnected: String
    let pairQR: String
    let manualConnect: String
    let disconnect: String
    let forgetDevice: String
    let uploadQueue: String
    let retryAll: String
    let clear: String
    let viewAll: String
    let discoveredDevices: String
    let searchingDevices: String
    let about: String
    let version: String
    let build: String
    let pasteJSON: String
    let connect: String
    let pairViaQR: String
    let scanQRHint: String
    let cameraRequired: String
    let cameraRequiredSubtitle: String
    let useManualInput: String
    let pasteQRHint: String
    let invalidQR: String
    let queueEmpty: String
    let noPendingUploads: String
    let retryAllFailed: String
    let clearAll: String
    let hostRequired: String
    let invalidPort: String
    let clipboardNoJSON: String
    let addressLabel: String
    let pasteTokenPlaceholder: String
    let connectDeviceTitle: String
    let manualLabel: String
    // Accessibility
    let a11yRecord: String
    let a11yStopRecording: String
    let a11yAddBookmark: String
    let a11ySendMessage: String
    let a11yClearSearch: String
    let a11ySessionList: String
    // Briefing source attribution
    let briefingViewSource: String
    let briefingSourceLoadFailed: String
    let briefingWeeklyThemes: String
    let briefingWeeklyPeople: String
    let briefingWeeklyKeyMoments: String
    /// Format string with a single %@ placeholder for the relative-time phrase,
    /// e.g. "Generated %@" + "3h ago" → "Generated 3h ago".
    let briefingGeneratedAtFormat: String
    let briefingQuoteSheetTitle: String
    let briefingAskAIPrefixFormat: String
    let briefingAskAI: String
    /// Hero placeholder shown when daily/weekly summary text is missing but other
    /// data (todos/items) exists — keeps the page feeling like a briefing, not a list.
    let briefingNoNarrativeTitle: String
    let briefingNoNarrativeSubtitle: String
    /// Section subtitle suffix showing item count, e.g. "3 items".
    let briefingItemCountFormat: String
    let briefingMoreActions: String
    // Live transcription language picker (Settings)
    let liveTranscriptionLanguageTitle: String
    let liveTranscriptionLanguageHelp: String
    let liveTranscriptionLanguageAuto: String
    let liveTranscriptionLanguageChinese: String
    let liveTranscriptionLanguageEnglish: String
    let liveTranscriptionLanguageMultilingual: String
    let transcriptionCorrectionTitle: String
    let transcriptionCorrectionHint: String
    // Form labels (Settings > Manual Connect)
    let formLabelHost: String
    let formLabelPort: String
    let formLabelToken: String
    // Public access (relay) — Settings > Manual Connect
    let publicAccessTitle: String
    let publicAccessHint: String
    let formLabelPublicHost: String
    let formLabelPublicPort: String
    let formLabelFingerprint: String
    // Generic error prefix, e.g. "Error: <details>"
    let errorPrefixFormat: String
    // Briefing regenerate
    let briefingRegenerate: String

    // Connection badge
    let connectedStatus: String
    let disconnectedStatus: String
    let connectingStatus: String
    let lookingForComputer: String
    let transportP2P: String
    let transportRelay: String
    let transportLan: String

    // Status
    let statusCompleted: String
    let statusProcessing: String
    let statusFailed: String

    // Detail tabs
    let summaryTab: String
    let timelineTab: String
    let transcriptTab: String
    let contentTab: String
    let ocrTextTab: String
    let paused: String
    let participants: String
    let decisions: String
    let actionItems: String
    let noTranscript: String

    // Bookmarks
    let bookmark: String
    let bookmarkAdded: String

    // Live Transcription
    let liveTranscript: String
    let streamingToDesktop: String
    let previewTranscript: String

    // Toast
    let recordingSaved: String
    let transcribing: String

    // Notifications
    let transcriptionComplete: String
    let transcriptionCompleteBody: String

    // Priority & Assignee
    let priorityUrgent: String
    let priorityLow: String
    let assigneeLabel: String

    // Type: Memo
    let typeMemo: String

    // Common
    let items: String

    // MARK: - English

    static let en = Strings(
        tabCapture: "Capture",
        tabSources: "Sources",
        tabAI: "AI",
        tabBriefing: "Briefing",
        tabSettings: "Settings",

        camera: "Camera",
        memo: "Memo",
        importFile: "Import",
        pending: "pending",
        failed: "failed",
        textMemo: "Text Memo",
        cancel: "Cancel",
        send: "Send",

        chooseImages: "Choose Images",
        recordVideo: "Record Video",
        chooseVideo: "Choose Video",
        photoCount: "photos",
        videoLimit: "Max 3 min",
        capture: "Capture",

        sources: "Sources",
        searchPlaceholder: "Search recordings...",
        filterAll: "All",
        filterVoice: "Voice",
        filterVideo: "Video",
        filterDocument: "Document",
        filterImage: "Image",
        filterText: "Text",
        noSources: "No Sources",
        noSourcesSubtitle: "Recordings will appear here after capture and sync",
        noResults: "No Results",
        noResultsSubtitle: "Try a different search term",
        summary: "Summary",
        extractedItems: "Extracted Items",
        transcript: "Transcript",
        notConnected: "Not connected",

        aiAssistant: "AI Assistant",
        askAnything: "Ask anything about your recordings",
        askPlaceholder: "Ask a question...",
        suggestToday: "What did I discuss today?",
        suggestMeetings: "Summarize my recent meetings",
        suggestTasks: "What are my pending tasks?",
        suggestPeople: "Who did I talk to this week?",
        suggestDecisions: "What decisions were made recently?",
        suggestSearch: "Search discussions about project planning",
        newSession: "New Session",
        sessions: "Sessions",
        done: "Done",
        listening: "LISTENING",
        speakNow: "Speak now...",
        sourcesLabel: "SOURCES",

        briefing: "Briefing",
        loading: "Loading...",
        summaryHeader: "SUMMARY",
        todosHeader: "TODOS",
        extractedHeader: "EXTRACTED",
        noBriefing: "No briefing data",
        noBriefingSubtitle: "No recordings processed for this date",
        weeklySummary: "WEEKLY SUMMARY",
        noSummary: "No summary available",
        noWeeklySummary: "No weekly summary",
        noWeeklySummarySubtitle: "Weekly summary not available for this period",
        daily: "Daily",
        weekly: "Weekly",

        settings: "Settings",
        connection: "Connection",
        connected: "Connected",
        disconnected: "Disconnected",
        pairQR: "Pair via QR Code",
        manualConnect: "Manual Connect",
        disconnect: "Disconnect",
        forgetDevice: "Forget This Device",
        uploadQueue: "Upload Queue",
        retryAll: "Retry All",
        clear: "Clear",
        viewAll: "View All",
        discoveredDevices: "Discovered Devices",
        searchingDevices: "Searching for DeepSeno desktops...",
        about: "About",
        version: "Version",
        build: "Build",
        pasteJSON: "Paste Link/JSON",
        connect: "Connect",
        pairViaQR: "Pair via QR",
        scanQRHint: "Scan the QR code shown in DeepSeno desktop settings",
        cameraRequired: "Camera access required",
        cameraRequiredSubtitle: "Enable camera in Settings to scan QR codes, or use manual input",
        useManualInput: "Use Manual Input",
        pasteQRHint: "Paste the QR link or legacy JSON from desktop settings",
        invalidQR: "Invalid pairing code",
        queueEmpty: "Queue Empty",
        noPendingUploads: "No pending uploads",
        retryAllFailed: "Retry All Failed",
        clearAll: "Clear All",
        hostRequired: "Host and token are required",
        invalidPort: "Invalid port number",
        clipboardNoJSON: "Clipboard has no valid JSON",
        addressLabel: "Address:",
        pasteTokenPlaceholder: "Paste token from desktop app",
        connectDeviceTitle: "Connect to Device",
        manualLabel: "Manual",
        a11yRecord: "Start recording",
        a11yStopRecording: "Stop recording",
        a11yAddBookmark: "Add bookmark",
        a11ySendMessage: "Send message",
        a11yClearSearch: "Clear search",
        a11ySessionList: "Chat sessions",
        briefingViewSource: "View source",
        briefingSourceLoadFailed: "Couldn't load source recording",
        briefingWeeklyThemes: "Themes",
        briefingWeeklyPeople: "People mentioned",
        briefingWeeklyKeyMoments: "Key moments",
        briefingGeneratedAtFormat: "Generated %@",
        briefingQuoteSheetTitle: "Original quote",
        briefingAskAIPrefixFormat: "About this item: %@",
        briefingAskAI: "Ask AI about this",
        briefingNoNarrativeTitle: "No narrative yet",
        briefingNoNarrativeSubtitle: "Today's recordings haven't been processed into a summary. Action items extracted so far are listed below.",
        briefingItemCountFormat: "%d items",
        briefingMoreActions: "More actions",
        liveTranscriptionLanguageTitle: "Transcription Language",
        liveTranscriptionLanguageHelp: "Multilingual runs Chinese and English recognizers in parallel; the dominant language wins per phrase. Uses ~2× battery.",
        liveTranscriptionLanguageAuto: "Auto",
        liveTranscriptionLanguageChinese: "中文",
        liveTranscriptionLanguageEnglish: "English",
        liveTranscriptionLanguageMultilingual: "中 + EN",
        transcriptionCorrectionTitle: "Polish transcript with AI",
        transcriptionCorrectionHint: "After each sentence, the desktop AI cleans up homophones, punctuation, and proper nouns.",
        formLabelHost: "HOST",
        formLabelPort: "PORT",
        formLabelToken: "TOKEN",
        publicAccessTitle: "Public Access",
        publicAccessHint: "Connect over the internet when away from your home network. Uses an encrypted, certificate-pinned channel to your desktop.",
        formLabelPublicHost: "PUBLIC HOST",
        formLabelPublicPort: "PUBLIC PORT",
        formLabelFingerprint: "FINGERPRINT",
        errorPrefixFormat: "Error: %@",
        briefingRegenerate: "Regenerate",

        connectedStatus: "Connected",
        disconnectedStatus: "Disconnected",
        connectingStatus: "Connecting…",
        lookingForComputer: "Looking for your computer…",
        transportP2P: "P2P Direct",
        transportRelay: "Encrypted Relay",
        transportLan: "LAN Direct",

        statusCompleted: "COMPLETED",
        statusProcessing: "PROCESSING",
        statusFailed: "FAILED",

        summaryTab: "Summary",
        timelineTab: "Timeline",
        transcriptTab: "Transcript",
        contentTab: "Content",
        ocrTextTab: "OCR Text",
        paused: "PAUSED",
        participants: "Participants",
        decisions: "Decisions",
        actionItems: "Action Items",
        noTranscript: "No transcript available",

        bookmark: "Bookmark",
        bookmarkAdded: "Bookmark added",

        liveTranscript: "Live Transcript",
        streamingToDesktop: "Streaming to desktop...",
        previewTranscript: "PREVIEW",

        recordingSaved: "Recording saved",
        transcribing: "Transcribing...",

        transcriptionComplete: "Transcription Complete",
        transcriptionCompleteBody: "has been transcribed",

        priorityUrgent: "Urgent",
        priorityLow: "Low",
        assigneeLabel: "Assignee",

        typeMemo: "Memo",

        items: "items"
    )

    // MARK: - Chinese

    static let zh = Strings(
        tabCapture: "采集",
        tabSources: "信息源",
        tabAI: "AI",
        tabBriefing: "简报",
        tabSettings: "设置",

        camera: "拍照",
        memo: "备忘",
        importFile: "导入",
        pending: "待处理",
        failed: "失败",
        textMemo: "文字备忘",
        cancel: "取消",
        send: "发送",

        chooseImages: "选择图片",
        recordVideo: "拍摄视频",
        chooseVideo: "选择视频",
        photoCount: "张照片",
        videoLimit: "最长 3 分钟",
        capture: "拍摄",

        sources: "信息源",
        searchPlaceholder: "搜索录音...",
        filterAll: "全部",
        filterVoice: "语音",
        filterVideo: "视频",
        filterDocument: "文档",
        filterImage: "图片",
        filterText: "文字",
        noSources: "暂无信息源",
        noSourcesSubtitle: "采集并同步后，录音将显示在此处",
        noResults: "无结果",
        noResultsSubtitle: "试试其他搜索词",
        summary: "摘要",
        extractedItems: "提取项",
        transcript: "转写",
        notConnected: "未连接",

        aiAssistant: "AI 助手",
        askAnything: "问任何关于你录音的问题",
        askPlaceholder: "输入问题...",
        suggestToday: "今天讨论了什么？",
        suggestMeetings: "总结最近的会议",
        suggestTasks: "我有哪些待办？",
        suggestPeople: "这周跟谁聊过？",
        suggestDecisions: "最近做了哪些决策？",
        suggestSearch: "搜索关于项目规划的讨论",
        newSession: "新会话",
        sessions: "会话列表",
        done: "完成",
        listening: "聆听中",
        speakNow: "请说话...",
        sourcesLabel: "来源",

        briefing: "简报",
        loading: "加载中...",
        summaryHeader: "摘要",
        todosHeader: "待办",
        extractedHeader: "提取项",
        noBriefing: "暂无简报",
        noBriefingSubtitle: "该日期没有已处理的录音",
        weeklySummary: "周报",
        noSummary: "暂无摘要",
        noWeeklySummary: "暂无周报",
        noWeeklySummarySubtitle: "该时间段暂无周报",
        daily: "日报",
        weekly: "周报",

        settings: "设置",
        connection: "连接",
        connected: "已连接",
        disconnected: "未连接",
        pairQR: "二维码配对",
        manualConnect: "手动连接",
        disconnect: "断开连接",
        forgetDevice: "忘记此设备",
        uploadQueue: "上传队列",
        retryAll: "全部重试",
        clear: "清空",
        viewAll: "查看全部",
        discoveredDevices: "发现的设备",
        searchingDevices: "正在搜索 DeepSeno 桌面端...",
        about: "关于",
        version: "版本",
        build: "构建号",
        pasteJSON: "粘贴链接/JSON",
        connect: "连接",
        pairViaQR: "扫码配对",
        scanQRHint: "扫描 DeepSeno 桌面端设置中显示的二维码",
        cameraRequired: "需要相机权限",
        cameraRequiredSubtitle: "在设置中开启相机权限以扫码，或使用手动输入",
        useManualInput: "手动输入",
        pasteQRHint: "粘贴桌面端设置中的二维码链接或旧版 JSON",
        invalidQR: "无效的配对码",
        queueEmpty: "队列为空",
        noPendingUploads: "没有待上传的内容",
        retryAllFailed: "重试全部失败项",
        clearAll: "全部清除",
        hostRequired: "主机地址和令牌不能为空",
        invalidPort: "端口号无效",
        clipboardNoJSON: "剪贴板中没有有效的 JSON",
        addressLabel: "地址:",
        pasteTokenPlaceholder: "粘贴桌面端令牌",
        connectDeviceTitle: "连接设备",
        manualLabel: "手动",
        a11yRecord: "开始录音",
        a11yStopRecording: "停止录音",
        a11yAddBookmark: "添加书签",
        a11ySendMessage: "发送消息",
        a11yClearSearch: "清除搜索",
        a11ySessionList: "聊天会话",
        briefingViewSource: "查看来源",
        briefingSourceLoadFailed: "无法加载来源录音",
        briefingWeeklyThemes: "主题",
        briefingWeeklyPeople: "提及人物",
        briefingWeeklyKeyMoments: "关键时刻",
        briefingGeneratedAtFormat: "生成于 %@",
        briefingQuoteSheetTitle: "原始引用",
        briefingAskAIPrefixFormat: "关于这条：%@",
        briefingAskAI: "针对此条问 AI",
        briefingNoNarrativeTitle: "今天的简报还没生成",
        briefingNoNarrativeSubtitle: "今天的录音尚未提炼出文字摘要，下方是目前已抽取出的事项。",
        briefingItemCountFormat: "%d 项",
        briefingMoreActions: "更多操作",
        liveTranscriptionLanguageTitle: "实时转写语言",
        liveTranscriptionLanguageHelp: "双语模式同时跑中文和英文识别器，按短语选取较强的那一种。耗电约 2 倍。",
        liveTranscriptionLanguageAuto: "自动",
        liveTranscriptionLanguageChinese: "中文",
        liveTranscriptionLanguageEnglish: "English",
        liveTranscriptionLanguageMultilingual: "中 + EN",
        transcriptionCorrectionTitle: "AI 校正实时转写",
        transcriptionCorrectionHint: "每句话结束后，由桌面端 AI 修正同音字、标点和专有名词。",
        formLabelHost: "主机",
        formLabelPort: "端口",
        formLabelToken: "令牌",
        publicAccessTitle: "公网接入",
        publicAccessHint: "离开家庭网络时通过互联网连接。使用加密且经证书校验（pinning）的通道连接到你的桌面端。",
        formLabelPublicHost: "公网主机",
        formLabelPublicPort: "公网端口",
        formLabelFingerprint: "证书指纹",
        errorPrefixFormat: "错误：%@",
        briefingRegenerate: "重新生成",

        connectedStatus: "已连接",
        disconnectedStatus: "未连接",
        connectingStatus: "连接中…",
        lookingForComputer: "正在查找电脑…",
        transportP2P: "穿透直连",
        transportRelay: "加密中继",
        transportLan: "局域网直连",

        statusCompleted: "已完成",
        statusProcessing: "处理中",
        statusFailed: "失败",

        summaryTab: "纪要",
        timelineTab: "时间轴",
        transcriptTab: "逐字稿",
        contentTab: "内容",
        ocrTextTab: "识别文字",
        paused: "已暂停",
        participants: "参会人",
        decisions: "决策",
        actionItems: "待办事项",
        noTranscript: "暂无转写内容",

        bookmark: "书签",
        bookmarkAdded: "已添加书签",

        liveTranscript: "实时转写",
        streamingToDesktop: "正在串流到桌面端...",
        previewTranscript: "预览",

        recordingSaved: "录音已保存",
        transcribing: "转写中...",

        transcriptionComplete: "转写完成",
        transcriptionCompleteBody: "已完成转写",

        priorityUrgent: "紧急",
        priorityLow: "低优先级",
        assigneeLabel: "负责人",

        typeMemo: "备忘",

        items: "项"
    )
}
