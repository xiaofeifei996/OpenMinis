// Offline tests compile the production policy file unchanged, not a copy of it.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct TodayWebLoginFixtures {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pair = "__Secure-better-auth.session_token=fixture==.signed"
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1; print("PASS: \(label)") }
            else { failed += 1; print("FAIL: \(label)") }
        }
        func cookie(name: String = "__Secure-better-auth.session_token",
                    domain: String = "todayai.cn", path: String = "/",
                    secure: Bool = true, value: String = "fixture==.signed",
                    expiry: Date? = nil) -> TodayWebLoginCookie {
            TodayWebLoginCookie(name: name, domain: domain, path: path,
                                isSecure: secure, value: value, expiresDate: expiry)
        }
        check(cookie().header(now: now) == pair, "secure session cookie")
        check(cookie(domain: ".todayai.cn").header(now: now) == pair, "root domain cookie")
        check(cookie(expiry: now.addingTimeInterval(1)).header(now: now) == pair, "future expiry")
        let rejected: [(String, TodayWebLoginCookie)] = [
            ("other cookie name", cookie(name: "session_token")),
            ("cookie name suffix", cookie(name: "__Secure-better-auth.session_token.evil")),
            ("cookie name case", cookie(name: "__secure-better-auth.session_token")),
            ("domain suffix attack", cookie(domain: "todayai.cn.evil.test")),
            ("domain prefix attack", cookie(domain: "eviltodayai.cn")),
            ("dotted suffix attack", cookie(domain: ".todayai.cn.evil.test")),
            ("www cookie not root scoped", cookie(domain: "www.todayai.cn")),
            ("dotted www cookie", cookie(domain: ".www.todayai.cn")),
            ("non-secure cookie", cookie(secure: false)),
            ("non-root path", cookie(path: "/api")),
            ("empty path", cookie(path: "")),
            ("expired cookie", cookie(expiry: now.addingTimeInterval(-1))),
            ("expiry boundary", cookie(expiry: now)),
            ("empty value", cookie(value: "")),
            ("CR injection", cookie(value: "fixture\rInjected: bad")),
            ("LF injection", cookie(value: "fixture\nInjected: bad")),
            ("CRLF injection", cookie(value: "fixture\r\nInjected: bad")),
            ("second cookie injection", cookie(value: "fixture; other=bad")),
            ("control byte", cookie(value: "fixture\u{0}bad")),
            ("whitespace", cookie(value: "fixture bad"))
        ]
        for (label, input) in rejected { check(input.header(now: now) == nil, label) }

        // Exercise the real Foundation HTTPCookie adapter as well as metadata
        // rejected by some platforms' cookie constructors before our code runs.
        func stored(_ value: String, domain: String = ".todayai.cn",
                    path: String = "/", secure: Bool = true) -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: "__Secure-better-auth.session_token", .value: value,
                .domain: domain, .path: path
            ]
            if secure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)!
        }
        let good = stored("fixture==.signed")
        check(TodayWebLoginCookie.header(from: [good], now: now) == pair, "HTTPCookie adapter")
        check(TodayWebLoginCookie.header(from: [], now: now) == nil, "empty store")
        check(TodayWebLoginCookie.header(from: [good, good], now: now) == pair, "identical duplicate")
        check(TodayWebLoginCookie.header(from: [good, stored("other-fixture")], now: now) == nil,
              "conflicting eligible cookies fail closed")
        check(TodayWebLoginCookie.header(from: [stored("fixture", domain: "todayai.cn.evil.test")], now: now) == nil,
              "HTTPCookie hostile domain")
        check(TodayWebLoginCookie.header(from: [stored("fixture", secure: false)], now: now) == nil,
              "HTTPCookie insecure")
        check(TodayWebLoginCookie.header(from: [stored("fixture", path: "/api")], now: now) == nil,
              "HTTPCookie wrong path")
        check(TodayWebLoginCookie.header(from: [good, stored("bad", domain: "www.todayai.cn")], now: now) == pair,
              "www page still requires actual eligible cookie domain")

        let allowed = ["https://todayai.cn/", "https://www.todayai.cn/login", "https://todayai.cn:443/"]
        for value in allowed {
            check(TodayWebLoginNavigation.allows(URL(string: value)), "allowed HTTPS navigation")
        }
        let blocked = [
            "http://todayai.cn/", "https://todayai.cn.evil.test/", "https://eviltodayai.cn/",
            "https://www.todayai.cn.evil.test/", "https://todayai.cn@evil.test/",
            "https://evil.test@todayai.cn/", "https://todayai.cn:444/", "https://todayai.cn./",
            "javascript:alert(1)", "data:text/html,hello", "file:///tmp/login.html",
            "tel:1234", "mailto:test@example.test", "minis://settings", "about:blank"
        ]
        for value in blocked {
            check(!TodayWebLoginNavigation.allows(URL(string: value)), "blocked navigation")
        }
        check(TodayWebLoginNavigation.allows(URL(string: "about:blank"), initialBlank: true), "initial blank")
        check(!TodayWebLoginNavigation.allows(URL(string: "about:blank#evil"), initialBlank: true), "blank spoof")
        check(!TodayWebLoginNavigation.allows(nil, initialBlank: true), "missing URL")

        var gate = TodayWebLoginAttempt()
        let old = gate.begin()!
        let current = gate.begin()!
        check(!gate.isCurrent(old), "replacement invalidates old read")
        check(!gate.finish(old), "old validation cannot complete")
        check(gate.isCurrent(current), "current validation remains eligible")
        var callbacks = 0
        if gate.finish(current) { callbacks += 1 }
        if gate.finish(current) { callbacks += 1 }
        check(callbacks == 1, "one-shot callback gate")
        check(gate.begin() == nil, "success is terminal")

        var canceled = TodayWebLoginAttempt()
        let late = canceled.begin()!
        canceled.close()
        if canceled.finish(late) { callbacks += 1 }
        check(callbacks == 1, "cancel forbids late callback")
        check(!canceled.isCurrent(late), "cancel invalidates read")
        check(canceled.begin() == nil, "cancel forbids retry")
        canceled.close()
        check(!canceled.finish(late), "idempotent close")

        var retry = TodayWebLoginAttempt()
        let abandoned = retry.begin()!
        retry.invalidate()
        check(!retry.finish(abandoned), "continue login rejects in-flight validation")
        let retried = retry.begin()!
        check(retry.finish(retried), "retry can succeed")

        print("TODAY_WEB_LOGIN_FIXTURES passed=\(passed) failed=\(failed)")
        if failed != 0 { exit(1) }
    }
}
