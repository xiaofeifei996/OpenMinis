import Foundation

/// The two WorkBuddy builds.
///
/// They share one login protocol (the plugin endpoints on `copilot.tencent.com`)
/// and almost nothing else: different chat host, different client fingerprint,
/// and the international build additionally requires the conversation to open
/// with a system message. Keeping the differences in one table is what lets the
/// flow, the manager and the factory stay single-implementation.
///
/// Values come from AgentHub's `workbuddy` / `workbuddy_ai` channel config
/// (v1.99.0), which read them off the desktop clients.
enum WorkBuddyRegion: String, Sendable, CaseIterable {
    case china
    case international

    var displayName: String {
        switch self {
        case .china: return "WorkBuddy 中国版"
        case .international: return "WorkBuddy AI（国际版）"
        }
    }

    /// Where the login/plugin endpoints live. NOT shared: the international
    /// build serves them from its own origin, and the plugin host is also the
    /// Origin/Referer the request must carry.
    var pluginHost: String {
        switch self {
        case .china: return "https://copilot.tencent.com"
        case .international: return "https://www.workbuddy.ai"
        }
    }

    /// The `platform` query on the auth-state request.
    ///
    /// `workbuddy` for both builds: AgentHub reads this from a per-channel
    /// `authPlatform` key that the international channel does not set, so its
    /// requests fall back to the same value the China build sends. Only the
    /// host differs.
    var pluginPlatform: String { "workbuddy" }

    /// The chat base. Already contains `/v2`, so `/v1` must not be appended.
    ///
    /// The international build also serves `/console/chat/completions`, and its
    /// gateway answers 404/405 on `/v2` when it wants that path. There is no
    /// automatic fallback here (the request builder has one URL); a user who
    /// hits it can put the console URL in the instance's custom base URL.
    var chatBase: String {
        switch self {
        case .china: return "https://copilot.tencent.com/v2"
        case .international: return "https://www.workbuddy.ai/v2"
        }
    }

    /// The catalog host, when it differs from the chat host.
    var catalogBase: String {
        switch self {
        case .china: return "https://copilot.tencent.com"
        case .international: return "https://www.workbuddy.ai"
        }
    }

    /// The three-segment UA is a fingerprint: the platform segment must read
    /// `WorkBuddy AI` on the international build (anything else is 403 code
    /// 11140), and the chat and catalog requests must present the same one.
    var clientVersion: String {
        switch self {
        case .china: return "5.6.2"
        case .international: return "5.8.4"
        }
    }

    var platformSegment: String {
        switch self {
        case .china: return "WorkBuddy"
        case .international: return "WorkBuddy AI"
        }
    }

    var cliVersion: String { "2.137.1" }

    /// `WorkBuddy/5.8.4 WorkBuddy AI/5.8.4 CLI/2.137.1`
    var userAgent: String {
        let v = clientVersion
        return "WorkBuddy/\(v) \(platformSegment)/\(v) CLI/\(cliVersion)"
    }

    var acceptLanguage: String {
        switch self {
        case .china: return "zh-CN"
        case .international: return "en-US"
        }
    }

    /// Value for `X-Domain`, which the gateway reads as the tenant hint.
    var domain: String {
        switch self {
        case .china: return "copilot.tencent.com"
        case .international: return "www.workbuddy.ai"
        }
    }

    /// `X-IDE-Name` / `X-IDE-Type`. `WorkBuddy` on both builds — only the
    /// User-Agent's middle segment carries `WorkBuddy AI`.
    var ideName: String { "WorkBuddy" }

    /// The international build rejects a conversation that does not start with
    /// a system message (`400 code 11128`), so one is inserted when missing.
    var requiresLeadingSystemMessage: Bool {
        self == .international
    }
}
