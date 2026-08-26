/*
 * Live AI Models
 * 实时对话数据模型 - 对话模式定义
 */

import Foundation

// MARK: - Live AI Response State

/// Provider-neutral state used by the foreground screen and the background
/// LiveAIManager. `waiting` includes model-side work such as web search; the
/// user should hear the eventual answer from the realtime audio stream.
enum LiveAIResponseState: String, Equatable {
    case idle
    case waiting
    case playing
    case failed

    var displayName: String {
        switch self {
        case .idle:
            return "liveai.status.ready".localized
        case .waiting:
            return "liveai.status.searching".localized
        case .playing:
            return "liveai.status.answering".localized
        case .failed:
            return "liveai.status.failed".localized
        }
    }
}

enum LiveAIWebSearchPolicy {
    /// Keep replies suitable for a user who may only hear the response
    /// through the glasses. Search is enabled at the provider level; this
    /// prompt only controls how the answer is spoken.
    static var instructions: String {
        if LanguageManager.staticIsChinese {
            return "\n\n【联网搜索与语音】遇到天气、新闻、价格、赛程或其他时效性问题时，使用联网搜索核实后再回答。先给结论并说明时间，不要朗读网址、引用编号或冗长来源。请用简短、自然、适合眼镜播报的口语回答。"
        }
        return "\n\n[WEB SEARCH AND VOICE] Use web search to verify weather, news, prices, schedules, and other time-sensitive questions before answering. Lead with the conclusion and mention the relevant time. Do not read URLs, citation numbers, or long source lists aloud. Keep answers short, natural, and suitable for glasses audio."
    }
}

enum LiveAIErrorMessage {
    /// Keep raw provider errors visible in the UI/logs, but use a short,
    /// actionable localized phrase for audio output. This prevents server
    /// diagnostics (URLs, status codes, or model internals) from being read
    /// aloud through the glasses.
    static func speech(for rawMessage: String) -> String {
        let message = rawMessage.lowercased()
        if message.contains("workspace") || message.contains("业务空间") {
            return "liveai.error.alibaba.workspace".localized
        }
        if message.contains("api key") || message.contains("apikey") ||
            message.contains("unauthorized") || message.contains("401") {
            return "liveai.error.apikey".localized
        }
        if message.contains("network") || message.contains("receive") ||
            message.contains("send") || message.contains("timeout") ||
            message.contains("连接") || message.contains("联网") {
            return "liveai.error.network".localized
        }
        return "liveai.error.generic".localized
    }
}

// MARK: - Live AI Input Mode

/// Controls whether a realtime Live AI session may access the glasses camera.
///
/// Voice mode is deliberately the default.  Selecting vision is an explicit
/// opt-in and is the only state in which a DAT camera session may be started
/// or an image may be appended to the realtime model session.
enum LiveAIInputMode: String, CaseIterable, Codable, Identifiable {
    case voice
    case vision

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voice:
            return "liveai.input.voice".localized
        case .vision:
            return "liveai.input.vision".localized
        }
    }

    var icon: String {
        switch self {
        case .voice:
            return "mic.fill"
        case .vision:
            return "eye.fill"
        }
    }

    var privacyDescription: String {
        switch self {
        case .voice:
            return "liveai.input.voice.privacy".localized
        case .vision:
            return "liveai.input.vision.privacy".localized
        }
    }

    /// Provider-neutral guard appended to the selected Live AI persona.
    /// It describes the input the model actually receives instead of merely
    /// advertising that the underlying model is vision-capable.
    var systemPromptConstraint: String {
        switch self {
        case .voice:
            return "prompt.liveai.input.voice".localized
        case .vision:
            return "prompt.liveai.input.vision".localized
        }
    }
}

// MARK: - Live AI Mode

enum LiveAIMode: String, CaseIterable, Codable, Identifiable {
    case standard = "standard"          // 默认模式 - 自由对话
    case museum = "museum"              // 博物馆模式
    case blind = "blind"                // 盲人模式
    case reading = "reading"            // 阅读模式
    case translate = "translate"        // 翻译模式
    case custom = "custom"              // 自定义提示词

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "liveai.mode.standard".localized
        case .museum:
            return "liveai.mode.museum".localized
        case .blind:
            return "liveai.mode.blind".localized
        case .reading:
            return "liveai.mode.reading".localized
        case .translate:
            return "liveai.mode.translate".localized
        case .custom:
            return "liveai.mode.custom".localized
        }
    }

    var icon: String {
        switch self {
        case .standard:
            return "brain.head.profile"
        case .museum:
            return "building.columns.circle"
        case .blind:
            return "figure.walk.circle"
        case .reading:
            return "text.viewfinder"
        case .translate:
            return "character.bubble"
        case .custom:
            return "pencil.circle"
        }
    }

    var description: String {
        switch self {
        case .standard:
            return "liveai.mode.standard.desc".localized
        case .museum:
            return "liveai.mode.museum.desc".localized
        case .blind:
            return "liveai.mode.blind.desc".localized
        case .reading:
            return "liveai.mode.reading.desc".localized
        case .translate:
            return "liveai.mode.translate.desc".localized
        case .custom:
            return "liveai.mode.custom.desc".localized
        }
    }

    /// 获取模式对应的系统提示词
    var systemPrompt: String {
        switch self {
        case .standard:
            return "prompt.liveai.standard".localized
        case .museum:
            return "prompt.liveai.museum".localized
        case .blind:
            return "prompt.liveai.blind".localized
        case .reading:
            return "prompt.liveai.reading".localized
        case .translate:
            // 翻译模式需要从 Manager 获取目标语言
            return "prompt.liveai.translate".localized
        case .custom:
            // 自定义模式需要从 Manager 获取
            return ""
        }
    }

    /// 是否在用户说话时自动发送图片
    var autoSendImageOnSpeech: Bool {
        switch self {
        case .standard:
            return true  // 默认模式：语音触发时发送图片
        case .museum, .blind, .reading, .translate:
            return true  // 这些模式都需要看图
        case .custom:
            return true  // 自定义模式也支持图片
        }
    }
}
