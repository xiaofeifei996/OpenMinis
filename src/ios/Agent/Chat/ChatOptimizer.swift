//
//  ChatOptimizer.swift
//  Minis — chat helpers: prompt rewrite ("优化词条"), latency speed-test,
//  auto-pick fastest model, auto-switch when a model becomes unavailable,
//  and 10s-no-first-token auto-retry.
//
//  All entry points are @MainActor: ProviderConfigStore, LLMProviderFactory,
//  AIChatViewModel and the View all live on the main actor.
//

import Foundation

// MARK: - Settings keys (UserDefaults via @AppStorage elsewhere)

enum ChatOptimizerSettings {
    /// Rewrite the composer text into a clearer prompt before sending.
    static let optimizePromptEnabled = "chatOptimizer.optimizePromptEnabled"
    /// Speed-test models and auto-pick the lowest-latency entry when the user
    /// has not pinned a specific model for the session.
    static let autoPickFastest = "chatOptimizer.autoPickFastest"
    /// When the active model becomes unavailable, silently switch to another
    /// available entry instead of failing.
    static let autoSwitchUnavailable = "chatOptimizer.autoSwitchUnavailable"
    /// If no first token arrives within `timeoutSeconds`, auto-retry once.
    static let autoRetryOnTimeout = "chatOptimizer.autoRetryOnTimeout"
    static let timeoutSeconds: TimeInterval = 10
    /// Latency cache: entryId -> best measured first-token latency (seconds).
    static let latencyCacheKey = "chatOptimizer.latencyCache"
}

// MARK: - Latency cache

struct ModelLatencyCache: Codable {
    var entries: [String: Double] = [:]
    /// Entry ids whose speed test failed (treated as unusable for auto-switch).
    var unavailable: [String] = []
    /// [T-speedtest-diag] Why a given entry failed, keyed by entry id.
    var errors: [String: String] = [:]
}

/// [T-speedtest-diag] Result of one latency probe: seconds on success, or the
/// failure reason (so the picker can explain a grey wifi).
struct LatencyProbe: Sendable {
    let seconds: Double?
    let error: String?
}

/// Errors surfaced by `ChatOptimizer`.
enum ChatOptimizerError: LocalizedError {
    case rewriteFailed(underlying: Error)
    case emptyRewrite
    var errorDescription: String? {
        switch self {
        case .rewriteFailed(let underlying):
            return String(format: AppLocalized("Prompt rewrite failed: %@", comment: "optimize rewrite failure"), underlying.localizedDescription)
        case .emptyRewrite:
            return AppLocalized("The rewrite returned nothing.", comment: "optimize returned nothing")
        }
    }
}

@MainActor
final class ChatOptimizer {
    static let shared = ChatOptimizer()

    private let store = ProviderConfigStore.shared
    private let userDefaults = UserDefaults.standard
    private let logger = AppLogger(category: "ChatOptimizer")

    private init() {}

    // MARK: Prompt rewrite ("优化词条")

    /// [T-latency] Completed-rewrite cache: key is trimmed original text.
    /// Lets a repeated tap on the same prompt return instantly instead of
    /// re-running the whole rewrite.
    private var rewriteCache: [String: String] = [:]

    /// In-flight rewrite keys, so a rapid re-tap on the same text does not
    /// fan out a duplicate network call.
    private var rewriteInFlight: Set<String> = []

    /// Rewrite `text` into a clearer prompt, yielding each delta as it arrives.
    /// Cache hits emit the full cached text immediately. If a rewrite for the
    /// exact same text is already in flight, the caller WAITS for it to land in
    /// the cache and replays the result.
    func optimizeStreaming(
        _ text: String,
        using entry: ModelEntry
    ) -> AsyncThrowingStream<String, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                if let cached = rewriteCache[trimmed] {
                    continuation.yield(cached)
                    continuation.finish()
                    return
                }
                if rewriteInFlight.contains(trimmed) {
                    // [T-optimize-dedup-wait] A rewrite for this exact text is
                    // already in flight. Do NOT return empty — wait (bounded) for
                    // it to land in the cache, then replay the finished rewrite.
                    for _ in 0..<60 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        if let c = rewriteCache[trimmed] {
                            continuation.yield(c)
                            break
                        }
                        if !rewriteInFlight.contains(trimmed) {
                            if let c = rewriteCache[trimmed] { continuation.yield(c) }
                            break
                        }
                    }
                    continuation.finish()
                    return
                }
                rewriteInFlight.insert(trimmed)
                defer { rewriteInFlight.remove(trimmed) }

                // [T-optimize-fallback] Try the active entry first, then other
                // available entries, so a model that hangs, returns nothing, or
                // just echoes the input verbatim falls back to a model that
                // actually rewrites. Bounded to 3 candidates.
                var candidates = [entry]
                for e in availableEntries() where e.id != entry.id {
                    if !candidates.contains(where: { $0.id == e.id }) {
                        candidates.append(e)
                        if candidates.count >= 3 { break }
                    }
                }
                var lastError: Error? = nil
                var didWriteCache = false
                for (idx, cand) in candidates.enumerated() {
                    do {
                        // [T-optimize-buffer-replay] Collect each candidate's
                        // deltas FIRST and only replay the winner. Streaming
                        // live let a model that echoed the input overwrite the
                        // composer with garbage, and the winner's rewrite got
                        // CONCATENATED onto the loser's.
                        var deltas: [String] = []
                        let stream = try await optimizeStreamForCandidate(trimmed, using: cand)
                        for try await chunk in stream {
                            if case .text(let delta) = chunk, !delta.isEmpty {
                                deltas.append(delta)
                            }
                        }
                        let out = deltas.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        if out.isEmpty {
                            lastError = ChatOptimizerError.emptyRewrite
                            continue
                        }
                        // [T-optimize-echo] A candidate that echoes the input
                        // back verbatim didn't rewrite anything. If another
                        // candidate remains, fall through to it; only accept an
                        // echo from the LAST candidate.
                        let isLast = idx == candidates.count - 1
                        if out == trimmed && !isLast {
                            continue
                        }
                        for d in deltas { continuation.yield(d) }
                        if self.rewriteCache.count >= 64 {
                            self.rewriteCache.removeAll(keepingCapacity: true)
                        }
                        self.rewriteCache[trimmed] = out
                        didWriteCache = true
                        break
                    } catch {
                        logger.warning("[optimize] candidate \(cand.model.id) failed: \(error.localizedDescription)")
                        lastError = error
                    }
                }
                if didWriteCache {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: lastError ?? ChatOptimizerError.emptyRewrite)
                }
            }
        }
    }

    /// Drop the cache entry for `text` (e.g. when the user edits the prompt).
    func invalidateRewriteCache(for text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rewriteCache.removeValue(forKey: trimmed)
    }

    /// Build ONE candidate's rewrite stream. The provider is created here so a
    /// failure (expired credential, network) throws to the caller, which then
    /// falls back to the next candidate.
    private func optimizeStreamForCandidate(
        _ text: String,
        using entry: ModelEntry
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = """
        你是一个提示词优化助手。请把用户给出的原始指令改写成更清晰、更专业、\
        更易于大模型理解的提示词。要求：
        - 保留用户真实意图，不要改变任务本身；
        - 补充必要的结构（如目标、约束、输出格式、语气）；
        - 删除口语化废话；
        - 保持简洁，尽量不超过原文的两倍长度；直接输出改写结果，不要解释、不要前后缀。
        - 用原文所用的语言改写：原文是中文就用中文，其他语言就用该语言。

        You are a prompt-rewrite assistant. Rewrite the user's instruction into a
        clearer, more precise prompt: keep the intent, add useful structure (goal,
        constraints, output format, tone), drop filler, stay under twice the
        original length, and output ONLY the rewritten prompt with no preamble.
        Write the result in the SAME language as the original text.
        """
        let messages: [LLMMessage] = [LLMMessage(role: .user, content: trimmed)]
        let provider = try await LLMProviderFactory.makeProvider(
            for: entry, sessionId: OpenCodeChannel.oneOffSessionId())
        return try await provider.streamMessage(
            messages: messages,
            systemPrompt: system,
            maxTokens: 384,
            temperature: 0.2
        )
    }

    /// Non-streaming convenience used by callers that only want the final text.
    func optimize(_ text: String, using entry: ModelEntry) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        var acc = ""
        for try await delta in optimizeStreaming(trimmed, using: entry) {
            acc += delta
        }
        let out = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? trimmed : out
    }

    // MARK: Latency speed-test

    private func readLatencyCache() -> ModelLatencyCache {
        guard let data = userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey),
              let c = try? JSONDecoder().decode(ModelLatencyCache.self, from: data) else {
            return ModelLatencyCache()
        }
        return c
    }

    private func writeLatencyCache(_ cache: ModelLatencyCache) {
        if let data = try? JSONEncoder().encode(cache) {
            userDefaults.set(data, forKey: ChatOptimizerSettings.latencyCacheKey)
        }
    }

    /// All entries that are usable: instance enabled, has credentials,
    /// not hidden, and not currently reported absent by the provider.
    func availableEntries() -> [ModelEntry] {
        var result: [ModelEntry] = []
        for instance in store.instances where instance.isEnabled && instance.hasAnyCredential {
            for entry in store.visibleEntries(for: instance.id) {
                guard !entry.isUnavailableFromProvider else { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// [T-speedtest-all-accounts] EVERY chat-capable model across EVERY configured
    /// account — enabled or not, hidden or not, previously-failed or not. This is
    /// what the manual "speed test all" button uses so a model that failed once is
    /// still retried (and can recover).
    ///
    /// Pure image/video/audio-generation models (no `textOutput`) are excluded:
    /// a chat ping against them always fails, and marking them "unavailable"
    /// would wrongly grey out models that work fine for their own modality.
    func allEntriesAcrossAccounts() -> [ModelEntry] {
        store.modelEntries.filter { entry in
            guard store.instance(for: entry.providerInstanceId) != nil else { return false }
            return entry.model.capabilities.supportedModalities.contains(.textOutput)
        }
    }

    /// Measure first-token latency for one entry using a tiny prompt.
    /// Returns seconds, or an error string on failure.
    func measureLatency(entry: ModelEntry, sessionId: String?) async -> LatencyProbe {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: "hi")
        ]
        // [T-speedtest-no-ui-session] When called from the model picker (no chat
        // open) sessionId is nil, and OpenCode-family accounts hard-400 without a
        // session id. Use a throwaway id so the probe actually fires; this is NOT
        // a chat turn, so no conversation state is touched.
        let effectiveSessionId: String? = {
            if let s = sessionId, !s.isEmpty, !s.hasPrefix("__new__") { return s }
            return OpenCodeChannel.oneOffSessionId()
        }()
        let start = Date()
        do {
            let provider = try await LLMProviderFactory.makeProvider(for: entry, sessionId: effectiveSessionId)
            // Use the streaming path so we can capture time-to-first-token.
            // [T-latency-min-output] Many OpenAI-compat services reject a tiny
            // max_tokens with HTTP 400, so a WORKING model showed the red ✗. The
            // probe is streaming and returns on the FIRST token, so a large
            // max_tokens costs nothing in latency.
            let stream = try await provider.streamMessage(
                messages: messages,
                systemPrompt: nil,
                maxTokens: 256,
                temperature: 0
            )
            for try await chunk in stream {
                if case .text(let t) = chunk, !t.isEmpty {
                    return LatencyProbe(seconds: Date().timeIntervalSince(start), error: nil)
                }
            }
            return LatencyProbe(seconds: nil, error: "no text returned")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // [T-latency-agent-path] The probe above sends the plain
            // `streamMessage` body. Gateways that validate the request against
            // the envelope the agent loop uses reject it outright — Raccoon
            // answers every model with `400 param model unsupport` even though
            // the same model chats fine, so its badges were all red crosses.
            // Retry once through the agent-shaped request before recording a
            // failure: a model that chats must not be reported as broken.
            logger.info("[latency] \(entry.id) plain probe failed (\(msg)); retrying via agent path")
            if let agentProbe = await probeViaAgentPath(entry: entry) { return agentProbe }
            logger.warning("[latency] \(entry.id) failed: \(msg)")
            return LatencyProbe(seconds: nil, error: msg)
        }
    }

    /// Speed-test fallback that mirrors what a real chat turn sends.
    ///
    /// `measureLatency` uses `LLMProvider.streamMessage`, which is the
    /// lightweight single-shot completion shape. Chat turns instead go through
    /// `AgentProvider.streamAgentMessage` — different message envelope, tools
    /// array, thinking parameters. Some gateways (Raccoon/小浣熊 among them)
    /// accept only the latter and answer the former with
    /// `400 param model unsupport`, which made every Raccoon badge a red cross
    /// while the models chatted normally moments later.
    ///
    /// Returns nil when the fallback also fails, so the caller keeps the
    /// original error — the accurate one for a genuinely broken model.
    private func probeViaAgentPath(entry: ModelEntry) async -> LatencyProbe? {
        let messages: [AgentMessage] = [
            AgentMessage(role: .user, parts: [.text("hi")])
        ]
        let start = Date()
        do {
            let provider = await AIChatViewModel.makeAgentProvider(
                for: entry, sessionId: OpenCodeChannel.oneOffSessionId())
            let stream = try await provider.streamAgentMessageClamped(
                messages: messages,
                systemPrompt: nil,
                tools: [],
                maxTokens: 256,
                thinkingLevel: .off
            )
            for try await event in stream {
                if case .textDelta(let t) = event, !t.isEmpty {
                    return LatencyProbe(seconds: Date().timeIntervalSince(start), error: nil)
                }
            }
            return LatencyProbe(seconds: nil, error: "no text returned")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.info("[latency] \(entry.id) agent-path probe failed: \(msg)")
            return nil
        }
    }

    /// Speed-test every available entry (respecting an overall budget), update
    /// the cache with the best latency seen per entry.
    // [T-speedtest-concurrency] 6 in flight: fast enough that a whole list
    // finishes in seconds, and the throttle guard below now absorbs the
    // gateway's 429 instead of recording every model as broken. Lower it here
    // (and in the picker's manual button) if a provider starts answering 429
    // on the very first probe.
    func speedTestAll(sessionId: String?, concurrency: Int = 6, perEntryTimeout: TimeInterval = 20,
                      includeAllAccounts: Bool = false, progress: ((Int, Int) -> Void)? = nil) async {
        // [T-speedtest-all-accounts] The manual button passes includeAllAccounts:
        // true so every model of every account is measured (and previously failed
        // ones get retried). Background auto-testing keeps the narrower set.
        let entries = includeAllAccounts ? allEntriesAcrossAccounts() : availableEntries()
        guard !entries.isEmpty else { return }
        progress?(0, entries.count)
        let cache = readLatencyCache()
        var updated = cache

        // [T-speedtest-live-update] Publish as each probe lands so entries fill
        // in progressively.
        //
        // [T-speedtest-publish-cheap] The payload IS the new value, and nothing
        // is persisted here. The first version wrote the whole cache to
        // UserDefaults and the picker decoded it back, for EVERY completion —
        // a JSON encode + disk write + JSON decode per probe, all on the main
        // actor. With concurrency 6 that saturated the main thread (the
        // reported scroll stutter) and coalesced SwiftUI updates so heavily
        // that the progress looked frozen (the reported "no live update").
        // The cache itself only needs to be durable when the run ends.
        // [T-speedtest-live-update] Put ONLY the non-nil value in the payload.
        //
        // The previous version stored `seconds as Any` with `seconds: Double?`,
        // so the value sitting in `userInfo` was an `Optional<Double>`, not a
        // `Double`. Readers did `as? Double`, which came back nil, so every
        // single-completion publish was interpreted as "clear this row" — the
        // numbers only ever appeared at the very end, when the whole cache was
        // re-adopted. Boxing the unwrapped value removes that trap.
        var info: [AnyHashable: Any] = [ChatOptimizer.latencyChangedIdsKey: [id]]
        if let seconds {
            info[ChatOptimizer.latencySecondsKey] = seconds
        } else if let error {
            info[ChatOptimizer.latencyErrorKey] = error
        }
        NotificationCenter.default.post(
            name: ChatOptimizer.latencyUpdatedNotification,
            object: nil,
            userInfo: info)

        // [T-speedtest-throttle-scope] A 429 belongs to ONE provider account.
        //
        // The first version stopped the whole run on the first throttle, so a
        // 56-model test died around entry 20 behind whichever provider happened
        // to rate-limit. Each provider now backs off on its own: its unmeasured
        // rows are parked, everything else keeps going, and the parked rows are
        // retried once after `throttleCooldown`.
        let throttleCooldown: TimeInterval = 8
        var blockedUntil: [String: Date] = [:]   // providerId → retry not before
        var queue = entries
        var retried: Set<String> = []            // entries given their one retry
        var done = 0

        await withTaskGroup(of: (String, String, LatencyProbe).self) { group in
            var inFlight = 0

            /// Take the next entry whose provider is not cooling down.
            func nextReady() -> ModelEntry? {
                let now = Date()
                return queue.first { entry in
                    guard let until = blockedUntil[entry.providerInstanceId] else { return true }
                    return now >= until
                }
            }

            func pump() {
                while inFlight < concurrency, let entry = nextReady() {
                    queue.removeAll { $0.id == entry.id }
                    inFlight += 1
                    group.addTask {
                        let probe = await self.measureLatency(entry: entry, sessionId: sessionId)
                        return (entry.id, entry.providerInstanceId, probe)
                    }
                }
            }

            pump()
            while inFlight > 0 || !queue.isEmpty {
                // Nothing in flight and nothing ready: everything left is
                // cooling down. Sleep until the earliest block lifts, drop the
                // blocks that have now expired, and try once more. If nothing is
                // ready after that, the remaining providers are unusable for
                // this run — stop instead of spinning.
                if inFlight == 0 {
                    guard let waitUntil = blockedUntil.values.min() else { break }
                    let wait = max(waitUntil.timeIntervalSinceNow, 0.2)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    blockedUntil = blockedUntil.filter { $0.value > Date() }
                    if nextReady() == nil {
                        logger.info("[latency] stopping with \(queue.count) unmeasured (provider still throttled)")
                        break
                    }
                    pump()
                    continue
                }

                guard let (id, providerId, probe) = await group.next() else { break }
                inFlight -= 1

                if let lat = probe.seconds {
                    updated.entries[id] = lat
                    updated.unavailable.removeAll { $0 == id }   // recovered
                    updated.errors.removeValue(forKey: id)
                    done += 1
                    progress?(done, entries.count)
                    publish(id: id, seconds: lat, error: nil)
                } else if Self.isThrottle(probe) {
                    // [T-speedtest-throttle] The ACCOUNT is rate limited, not
                    // this model: leave no error behind and back this provider
                    // off. Its row keeps waiting and gets one retry.
                    updated.errors.removeValue(forKey: id)
                    blockedUntil[providerId] = Date().addingTimeInterval(throttleCooldown)
                    if !retried.contains(id), let original = entries.first(where: { $0.id == id }) {
                        retried.insert(id)
                        queue.append(original)
                    }
                    logger.info("[latency] \(providerId.prefix(8)) throttled; backing off, \(queue.count) pending")
                    publish(id: id, seconds: nil, error: nil)   // clear any badge
                } else {
                    // [T-speedtest-soft-fail] A failed speed test is NOT proof the
                    // model is unusable — transient network/auth blips would wrongly
                    // grey out working models. So we only RECORD the failure reason
                    // for the UI, and do NOT add it to `unavailable` (which feeds
                    // auto-switch). The grey wifi is driven by `errors`, not
                    // `unavailable`.
                    updated.errors[id] = probe.error
                    done += 1
                    progress?(done, entries.count)
                    publish(id: id, seconds: nil, error: probe.error)
                }
                pump()
                // [T-speedtest-live-update] Yield to the main actor between
                // probes: the whole run is @MainActor-isolated (provider setup
                // and stream parsing included), so without this the next probe
                // starts before SwiftUI gets a chance to draw the row we just
                // published — which is exactly what "not in real time" looked
                // like. One yield per completion is free.
                await Task.yield()
            }
        }

        // Persist once at the end: the cache only needs to be durable between
        // runs. Writing it per completion was a JSON encode + disk write on the
        // main actor for every probe — pure cost, no benefit.
        writeLatencyCache(updated)
        NotificationCenter.default.post(name: ChatOptimizer.latencyUpdatedNotification, object: nil)
    }

    /// Posted after a background speed test finishes so list rows can refresh.
    ///
    /// [T-speedtest-live-update] `userInfo` may carry
    /// `latencyChangedIdsKey` — the entry ids this publish touched. The picker
    /// patches just those rows; an absent list means "re-read everything"
    /// (the end of a run, or a wholesale cache reset).
    static let latencyUpdatedNotification = Notification.Name("chatOptimizer.latencyUpdated")
    static let latencyChangedIdsKey = "entryIds"
    /// A live publish carries the measured value (Double) or the error (String)
    /// for the named entry, so the picker never has to re-read the cache.
    static let latencySecondsKey = "seconds"
    static let latencyErrorKey = "error"

    /// Whether a probe failure means "the account is being throttled" rather
    /// than "this model is broken".
    ///
    /// Speed-testing hammers the gateway with one request per model; a rate
    /// limit is a fact about the ACCOUNT at this instant, not about the model.
    /// Recording it as a model error painted every row of a throttled provider
    /// with a red cross (the reported 小浣熊 case: all seven models "Rate
    /// limited" while the account was fine), which reads as "this provider is
    /// dead". Treating it as back-off information keeps the badges honest and
    /// stops the run from burning the whole quota in one burst.
    private static func isThrottle(_ probe: LatencyProbe) -> Bool {
        guard let error = probe.error?.lowercased() else { return false }
        return error.contains("rate limited")
            || error.contains("rate limit")
            || error.contains("429")
            || error.contains("too many requests")
    }

    /// The fastest available entry per the latency cache, or nil if untested.
    func fastestEntry() -> ModelEntry? {
        let cache = readLatencyCache()
        let entries = availableEntries()
        guard !cache.entries.isEmpty else { return nil }
        return entries.min(by: { (a, b) -> Bool in
            let la = cache.entries[a.id] ?? Double.greatestFiniteMagnitude
            let lb = cache.entries[b.id] ?? Double.greatestFiniteMagnitude
            return la < lb
        })
    }

    /// Ensure the active entry is still usable; if not and auto-switch is on,
    /// return a replacement entry. Returns nil when no switch is needed.
    func replacementIfUnavailable(_ active: ModelEntry?) -> ModelEntry? {
        guard let active = active else { return nil }
        // Provider-delisted models are hard-unavailable. Speed-test failures are
        // NOT treated as unavailable here (soft-fail), so they don't trigger a
        // pre-send swap — only a real call-time error does (via the watchers).
        if let inst = store.instance(for: active.providerInstanceId),
           inst.isEnabled, inst.hasAnyCredential, !active.isHidden,
           !active.isUnavailableFromProvider {
            return nil
        }
        // Find another available entry (prefer same instance, then any).
        let others = availableEntries().filter { $0.id != active.id }
        if let sameInstance = others.first(where: { $0.providerInstanceId == active.providerInstanceId }) {
            return sameInstance
        }
        return others.first
    }

    // MARK: - Auto-pick / auto-switch wiring

    /// Switch a session's primary binding to the given entry (direct entry, no
    /// group), preserving any existing sub-model binding. Persists via
    /// `ProviderConfigStore.setBinding` and bumps `configRevision` so the VM's
    /// `resolveCurrentEntry` cache re-resolves on the next access.
    private func bindSession(_ sessionId: String, to entry: ModelEntry) {
        let existing = store.binding(for: sessionId)
        let binding = SessionModelBinding(
            sessionId: sessionId,
            primarySource: .directEntry(modelEntryId: entry.id, compositeKey: entry.compositeKey),
            subModelSource: existing?.subModelSource
        )
        store.setBinding(binding, for: sessionId)
        // Keep the session row's displayed model id in sync.
        Task {
            await ChatStore.shared.updateSessionModelId(sessionId, modelId: entry.model.id)
        }
        NotificationCenter.default.post(
            name: .sessionModelBindingChanged,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    /// Resolve the current entry for a session, honoring the live binding.
    private func currentEntry(for sessionId: String) -> ModelEntry? {
        guard let binding = store.binding(for: sessionId) else { return nil }
        let entryId: String
        switch binding.primarySource {
        case .directEntry(let eid, _): entryId = eid
        case .group(_, let eid): entryId = eid
        }
        return store.entry(for: entryId)
    }

    /// True when the user has explicitly pinned a model for this session
    /// (a direct-entry binding). When the binding routes through the default
    /// group — i.e. the user never picked a specific model — auto-pick may
    /// override it.
    private func isManuallyPinned(for sessionId: String) -> Bool {
        guard let binding = store.binding(for: sessionId) else { return false }
        if case .directEntry = binding.primarySource { return true }
        return false
    }

    /// Whether `autoPickFastest` is enabled (AppStorage-backed UserDefaults).
    private var autoPickFastestEnabled: Bool {
        UserDefaults.standard.bool(forKey: ChatOptimizerSettings.autoPickFastest)
    }

    /// Whether `autoSwitchUnavailable` is enabled (AppStorage-backed UserDefaults).
    /// [T-auto-switch-default-on] Default TRUE: if the user has never touched the
    /// setting, auto-switch on provider error should be on. `bool(forKey:)`
    /// returns false when unset, so explicitly treat "unset" as enabled.
    var autoSwitchUnavailableEnabled: Bool {
        if UserDefaults.standard.object(forKey: ChatOptimizerSettings.autoSwitchUnavailable) == nil {
            return true   // unset → default ON
        }
        return UserDefaults.standard.bool(forKey: ChatOptimizerSettings.autoSwitchUnavailable)
    }

    /// Apply the auto-pick-fastest and auto-switch-unavailable rules before a
    /// send. Called from the composer's `performSend` (on @MainActor) with the
    /// session id that this turn belongs to. Any rule that changes the binding
    /// persists it (via `setBinding`, which bumps `configRevision`).
    ///
    /// - Returns: true if the active binding was changed.
    @discardableResult
    func applyAutoRules(
        sessionId: String,
        beforeSpeedTest: (() -> Void)? = nil,
        speedTest: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        guard !sessionId.isEmpty else { return false }
        var changed = false

        // 1) Auto-switch unavailable: if the current entry is unusable, swap it.
        if autoSwitchUnavailableEnabled {
            let active = currentEntry(for: sessionId)
            if let replacement = replacementIfUnavailable(active) {
                bindSession(sessionId, to: replacement)
                changed = true
                logger.info("[autoSwitch] session=\(sessionId.prefix(8)) switched \(active?.id ?? "nil") → \(replacement.id)")
            }
        }

        // 2) Auto-pick fastest: only when the user has NOT pinned a specific model.
        if autoPickFastestEnabled, !isManuallyPinned(for: sessionId) {
            let cache = readLatencyCache()
            if cache.entries.isEmpty {
                // No latency data yet: kick off a background speed test (non-blocking)
                // and don't change the binding this turn.
                beforeSpeedTest?()
                if let speedTest {
                    Task { await speedTest() }
                } else {
                    Task { await self.speedTestAll(sessionId: sessionId) }
                }
            } else if let fastest = fastestEntry() {
                let active = currentEntry(for: sessionId)
                if active?.id != fastest.id {
                    bindSession(sessionId, to: fastest)
                    changed = true
                    logger.info("[autoPick] session=\(sessionId.prefix(8)) picked fastest \(fastest.id) (was \(active?.id ?? "nil"))")
                }
            }
        }

        return changed
    }

    /// Force-switch the session to another usable model after a send failure
    /// (e.g. backend 404 "model not found"). Unlike `replacementIfUnavailable`,
    /// this does NOT require the failed model to already be flagged unavailable —
    /// it simply moves to the next available entry so the turn can be retried.
    /// Returns true if a switch happened.
    func switchToNextAvailable(sessionId: String) -> Bool {
        let active = currentEntry(for: sessionId)
        // [T-speedtest-soft-fail] Speed-test failures don't hard-exclude a model,
        // but when picking a replacement we PREFER models we know work (a measured
        // latency), then untested ones, and only last the ones that just failed —
        // otherwise we'd keep swapping into other broken models.
        let cache = readLatencyCache()
        let pool = availableEntries().filter {
            $0.id != active?.id &&
            !$0.isUnavailableFromProvider && !$0.isHidden
        }
        let known = pool.filter { cache.entries[$0.id] != nil }
        let untested = pool.filter { cache.entries[$0.id] == nil && cache.errors[$0.id] == nil }
        let failed = pool.filter { cache.errors[$0.id] != nil && cache.entries[$0.id] == nil }
        guard let replacement = (known.first ?? untested.first ?? failed.first) else { return false }
        bindSession(sessionId, to: replacement)
        logger.info("[autoSwitch] on-failure switched \(active?.id ?? "nil") → \(replacement.id)")
        return true
    }

    /// Ensure latency data exists; if empty, run a (non-blocking) speed test.
    /// Safe to call from app launch / picker appear. No-op if already populated.
    /// `sessionId` is a real session used so OpenCode-routed models can be tested.
    func ensureLatencyDataOnce(sessionId: String?) async {
        // [T-speedtest-throttle] An earlier run could have been throttled and
        // recorded "Rate limited" against every model of that provider, which
        // painted whole sections red. Those are account facts, not model
        // defects, so drop them before deciding whether data is missing —
        // otherwise the red crosses persist forever (the cache is non-empty, so
        // nothing would ever re-test them).
        var cache = readLatencyCache()
        let staleThrottle = cache.errors.filter { key, _ in
            cache.entries[key] == nil && Self.isThrottle(LatencyProbe(seconds: nil, error: cache.errors[key]))
        }
        if !staleThrottle.isEmpty {
            for key in staleThrottle.keys { cache.errors.removeValue(forKey: key) }
            writeLatencyCache(cache)
            NotificationCenter.default.post(name: Self.latencyUpdatedNotification, object: nil)
            logger.info("[latency] cleared \(staleThrottle.count) stale throttle error(s)")
        }
        guard cache.entries.isEmpty else { return }
        // [T-speedtest-sequential] Serial here too: this fires on the picker's
        // first appear, and 6 concurrent probes on the main actor made that
        // first open stutter before the user even asked for a test.
        await speedTestAll(sessionId: sessionId, concurrency: 1)
    }

    /// Public read-only view of the latency cache for UI (model picker badges).
    var latencyCache: ModelLatencyCache {
        readLatencyCache()
    }
}
