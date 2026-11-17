# Model wait visibility and recovery

A completed tool card means the tool returned, not that the next model request
has established its response stream. The previous 120-second watchdog began
only after `streamAgentMessage` returned a stream. Credential lookup, request
submission and response headers could therefore leave the UI displaying a
single, indefinite thinking label.

This update covers model-request establishment with a deadline using the
provider's configured idle timeout (120 seconds by default). A single-resume
gate returns timeout/cancellation without joining an uncooperative opener.
Late results cannot be consumed as another answer or schedule tools. Timeout
uses the existing retry/fallback path; completed tool results stay in history.
Cancelling a turn is propagated ahead of retry/fallback classification.

The live message footer displays the request stage and elapsed seconds:
preparing, connecting, awaiting content, hidden reasoning, retry countdown or
an explicit background/browser-takeover pause. The per-second tick is local to
the footer; it does not publish through the whole message list. A single-line
layout avoids introducing footer height changes every second.

Repeated usage/model metadata no longer extend the model-progress deadline.
Hidden reasoning is still genuine progress. Watchdog firing validates its wait
snapshot atomically before diagnostic actor hops. A later wait cannot be killed
by a stale timeout check.

OpenAI Responses `response.completed` and Anthropic `message_stop` finish
consumption after final metadata/tool flushing, without waiting for transport
EOF. Chat Completions keeps its existing usage-tail behavior.

Validation:

- `scripts/test_model_wait.py` extracts the production gate/watchdog and checks
  deadline return with an uncooperative opener, late completion, pre-cancel,
  cancellation during open, single-resume races and progress classification.
- `scripts/test_wait_presentation.py` compiles the production message wait
  properties and SwiftUI indicator, and checks the real footer/terminal wiring.
- The existing `StreamStallWatchdogTests.swift` covers 500 consecutive waits,
  pre-cancellation and post-timeout waiters.
- Full Xcode build validates integration.

Limitations: iOS suspension can delay timers; an arbitrary provider that ignores
cancellation may retain its underlying resources until it returns. The gate
prevents late results from reaching the conversation but does not claim to
forcibly terminate such external work. Real-device intermittent network stalls
still need field verification; a screenshot alone cannot identify which await
was stalled.
