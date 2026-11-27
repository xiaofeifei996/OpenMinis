import SwiftUI
import WebKit

/// Credentials are entered only in the official website. The completion value
/// is one validated Cookie header pair, not a token read from page JavaScript.
@MainActor
struct TodayWebLoginSheet: View {
    let onComplete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = TodayWebLoginController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Sign in on the official Today AI page. Enter your phone number and verification code there; Minis does not collect them.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                TodayLoginWebView(model: model)

                if model.pageFailed {
                    Text("The Today AI page could not be loaded. Please try again.")
                        .font(.footnote)
                    Button("Reload page") { model.reloadPage() }
                }
                if model.status == .failed {
                    Text("We couldn't verify the session. Check your connection or sign in again.")
                        .font(.footnote)
                        .foregroundColor(.red)
                    HStack {
                        Button("Retry") { model.checkSession() }
                        Button("Continue signing in") { model.continueLogin() }
                    }
                } else if model.isChecking {
                    HStack {
                        ProgressView()
                        Text("Reading Today AI session status…").font(.footnote)
                    }
                } else {
                    Text("After signing in, tap “I've finished signing in” to check the session.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Button("I've finished signing in") { model.checkSession() }
                    .disabled(model.isChecking)
                    .padding(.bottom)
            }
            .navigationTitle("Today AI Website Login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.close()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Capture only the caller and dismissal action, not this View's
            // StateObject (which would form a model -> completion -> model cycle).
            model.start { [onComplete, dismiss] cookie in
                onComplete(cookie)
                dismiss()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.checkSession() }
            else { model.continueLogin() }
        }
        .onDisappear { model.close() }
    }
}

@MainActor
private struct TodayLoginWebView: UIViewRepresentable {
    let model: TodayWebLoginController

    func makeCoordinator() -> TodayWebLoginController { model }
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: TodayWebLoginController) {
        coordinator.close()
    }
}

@MainActor
private final class TodayWebLoginController: NSObject, ObservableObject,
    WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    enum Status { case waiting, checking, validating, failed }
    @Published private(set) var status: Status = .waiting
    @Published private(set) var pageFailed = false

    let webView: WKWebView
    private let dataStore: WKWebsiteDataStore
    private var attempt = TodayWebLoginAttempt()
    private var checkTask: Task<Void, Never>?
    private var completion: ((String) -> Void)?
    private var started = false
    private var closed = false
    private var observing = false
    private var initialBlank = true

    var isChecking: Bool { status == .checking || status == .validating }

    override init() {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        dataStore = store
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
    }

    func start(onComplete: @escaping (String) -> Void) {
        guard !started, !closed else { return }
        started = true
        completion = onComplete
        webView.navigationDelegate = self
        webView.uiDelegate = self
        dataStore.httpCookieStore.add(self)
        observing = true
        reloadPage()
    }

    func reloadPage() {
        guard started, !closed else { return }
        continueLogin()
        pageFailed = false
        webView.load(URLRequest(url: URL(string: "https://todayai.cn/login")!))
    }

    func continueLogin() {
        guard !closed else { return }
        attempt.invalidate()
        checkTask?.cancel()
        checkTask = nil
        status = .waiting
    }

    func checkSession() {
        // Cookie-store and navigation notifications can arrive in bursts. Keep
        // one read-only validation in flight; it re-reads the cookie afterward.
        guard started, !closed, checkTask == nil, let ticket = attempt.begin() else { return }
        status = .checking
        let store = dataStore.httpCookieStore
        // No strong self binding survives an await: closing the sheet must not
        // retain its controller until a provider/network task eventually exits.
        checkTask = Task { @MainActor [weak self] in
            let cookies = await store.allCookies()
            guard !Task.isCancelled, self?.attempt.isCurrent(ticket) == true else { return }
            guard let header = TodayWebLoginCookie.header(from: cookies) else {
                self?.status = .waiting
                self?.checkTask = nil
                return
            }
            self?.status = .validating
            do {
                // A successful empty result is valid. Never send a chat probe.
                _ = try await TodayProvider.fetchModels(sessionCookie: header)
                try Task.checkCancellation()
                // Re-read after validation, including expiration: a replacement
                // or deletion must never complete using the earlier snapshot.
                let latest = await store.allCookies()
                try Task.checkCancellation()
                guard self?.attempt.isCurrent(ticket) == true else { return }
                guard TodayWebLoginCookie.header(from: latest) == header else {
                    self?.checkTask = nil
                    self?.checkSession()
                    return
                }
                self?.complete(header, ticket: ticket)
            } catch {
                guard !Task.isCancelled, self?.attempt.isCurrent(ticket) == true else { return }
                // Never display error descriptions or response bodies: they may
                // contain a server-echoed credential.
                self?.status = .failed
                self?.checkTask = nil
            }
        }
    }

    private func complete(_ header: String, ticket: UUID) {
        guard !closed, attempt.finish(ticket) else { return }
        let callback = completion
        close()
        callback?(header)
    }

    func close() {
        guard !closed else { return }
        closed = true
        attempt.close()
        checkTask?.cancel()
        checkTask = nil
        completion = nil
        if observing {
            dataStore.httpCookieStore.remove(self)
            observing = false
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // The isolated in-memory store is discarded with this controller.
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // Do not move the non-Sendable delegate argument across isolation.
        Task { @MainActor [weak self] in self?.checkSession() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageFailed = false
        checkSession()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        continueLogin()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handlePageFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handlePageFailure(error)
    }

    private func handlePageFailure(_ error: Error) {
        guard !closed, (error as NSError).code != NSURLErrorCancelled else { return }
        pageFailed = true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !closed, !navigationAction.shouldPerformDownload,
              TodayWebLoginNavigation.allows(navigationAction.request.url, initialBlank: initialBlank) else {
            decisionHandler(.cancel)
            return
        }
        let isBlank = navigationAction.request.url?.absoluteString == "about:blank"
        if !isBlank { initialBlank = false }
        if navigationAction.targetFrame == nil {
            // Never open Safari, another WKWebView, or an external scheme.
            // Cancel first, then route only an already-allowlisted HTTPS URL.
            continueLogin()
            decisionHandler(.cancel)
            if !isBlank { webView.load(navigationAction.request) }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true { continueLogin() }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !closed, navigationResponse.canShowMIMEType,
              TodayWebLoginNavigation.allows(navigationResponse.response.url, initialBlank: initialBlank) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // targetFrame == nil is handled by the navigation policy above.
        nil
    }
}
