import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Foundation-only policy shared by the WebKit sheet and executable fixtures.
/// Never serialize unrelated website cookies into the provider credential.
struct TodayWebLoginCookie: Sendable {
    let name: String
    let domain: String
    let path: String
    let isSecure: Bool
    let value: String
    let expiresDate: Date?

    func header(now: Date = Date()) -> String? {
        guard name == "__Secure-better-auth.session_token",
              domain == "todayai.cn" || domain == ".todayai.cn",
              isSecure, path == "/", !value.isEmpty,
              !value.contains("\r"), !value.contains("\n"),
              !value.contains(";"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              expiresDate.map({ $0 > now }) ?? true else { return nil }
        return "__Secure-better-auth.session_token=\(value)"
    }

    static func header(from cookies: [HTTPCookie], now: Date = Date()) -> String? {
        let headers = Set(cookies.compactMap { cookie in
            Self(name: cookie.name, domain: cookie.domain, path: cookie.path,
                 isSecure: cookie.isSecure, value: cookie.value,
                 expiresDate: cookie.expiresDate).header(now: now)
        })
        // Conflicting eligible cookies must not silently select an account.
        guard headers.count == 1 else { return nil }
        return headers.first
    }
}

enum TodayWebLoginNavigation {
    static func allows(_ url: URL?, initialBlank: Bool = false) -> Bool {
        guard let url else { return false }
        if initialBlank && url.absoluteString == "about:blank" { return true }
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "todayai.cn" || host == "www.todayai.cn"
    }
}

/// Main-actor-owned by the sheet. A new read invalidates every older read or
/// validation; closing and finishing are terminal, including for late tasks.
struct TodayWebLoginAttempt {
    private var active = true
    private var current: UUID?

    mutating func begin() -> UUID? {
        guard active else { return nil }
        let ticket = UUID()
        current = ticket
        return ticket
    }

    func isCurrent(_ ticket: UUID) -> Bool { active && current == ticket }

    mutating func finish(_ ticket: UUID) -> Bool {
        guard isCurrent(ticket) else { return false }
        close()
        return true
    }

    mutating func invalidate() { current = nil }

    mutating func close() {
        active = false
        current = nil
    }
}
