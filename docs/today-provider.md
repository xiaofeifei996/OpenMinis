# Today AI native provider

## Scope

Experimental text-only adapter for `todayai.cn`. This is **not** an OpenAI-compatible base URL. Configure the browser session Cookie in the protected credential field; it is stored in the existing API-key Keychain slot. Never commit a real Cookie, JWT or captured authenticated response.

The adapter exchanges the Cookie at `/api/token`, discovers account model options at `/api/cloud/v1/pricing/status`, selects the account model option, submits canonical-v1 `/v1/messages`, then polls `/v1/conversations/messages`. It emits a completed text snapshot, not token-by-token SSE. Empty/nullable catalogs are not replaced with an invented list of available models.

## Important limitations

- Requests use the account's **shared main chat**. This can affect the website conversation and the server may retain earlier account context. Supplying the caller's transcript does not make the upstream main chat private or stateless. Do not use this adapter where strict local-session isolation is required.
- Model selection is account-global. Concurrent probes, another client or the website can change the selected model between selection and submission; no per-request model binding is promised.
- Native tools, images, attachments and reasoning controls are not supported. `maxTokens` and temperature are not guaranteed by this upstream protocol.
- Cancel stops local polling/network waiting; no verified server-side abort/stop-billing endpoint is implemented. Cancelling does not promise refund or termination of generation.
- Only replies linked to this request's clientMessageId are accepted. An older server omitting linkage fields will time out rather than return another conversation's text. A busy shared chat can push replies beyond the bounded history page.
- Interrupted, empty and timed-out generations are errors, not successful partial completions. Send operations are not retried on transient failures; authentication gets at most one refresh retry and reuses the same clientMessageId.

## Protocol evidence

Reviewed publicly available source, not a live authenticated account:

- https://github.com/jzPPP3333/cpa-today-plugin/blob/18d79b87bd077b8cb72468bf304d9cdfdb7d866b/internal/today/client.go
- https://github.com/misakano7545/today2api-panel/blob/2bf5c326d2a8767010db48e73a7e06966343a3bc/internal/today/chat.go
- Official public JS, fetched 2026-11-27: `https://todayai.cn/_next/static/chunks/0tldm70om_pw8.js` (schemas), `3p95iox45q78p.js` (JWT), `2_67k-6n7ot63.js` (model options). Asset names are not stable protocol guarantees.

Public unauthenticated probes reached the token/pricing/history authentication gates, but **do not validate authenticated response compatibility or successful chat**. Fixture tests validate our encoding/decoding, not upstream availability. Full Xcode compilation and a separately authorized live-account test are required before declaring the integration usable.
