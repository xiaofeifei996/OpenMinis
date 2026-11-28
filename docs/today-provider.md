# Today AI native provider

## Scope

Experimental text-chat adapter for `todayai.cn`. This is **not** an OpenAI-compatible base URL. Configure the browser session Cookie in the protected credential field; it is stored in the existing API-key Keychain slot. Never commit a real Cookie, JWT or captured authenticated response.

The adapter exchanges the Cookie at `/api/token`, discovers account model options at `/api/cloud/v1/pricing/status`, selects the account model option, submits canonical-v1 `/v1/messages`, then polls `/v1/conversations/messages`. It emits one completed text snapshot per submitted user turn, not token-by-token SSE. Text attachments in the session upload folder (JSON, TXT, CSV, Markdown, YAML, XML and listed source formats) are read locally and inlined into that text request under per-file and total size limits. Empty/nullable catalogs are not replaced with an invented list of available models.

## Important limitations

- Requests use the account's **shared main chat**. This can affect the website conversation and the server may retain earlier account context. Supplying the caller's transcript does not make the upstream main chat private or stateless. Do not use this adapter where strict local-session isolation is required.
- Model selection is account-global. Concurrent probes, another client or the website can change the selected model between selection and submission; no per-request model binding is promised.
- Native tools, images, PDFs and other binary attachments are not supported. Authorized UTF-8 text attachments are extracted locally; each file is limited to **128 KiB (131,072 bytes)** and the current turn is limited to **256 KiB (262,144 bytes)** across all attachment blocks and text parts. Expanded text is also checked against the model's remaining context budget before submission. `maxTokens` and temperature are not guaranteed by this upstream protocol.
- Cancel stops local polling/network waiting; no verified server-side abort/stop-billing endpoint is implemented. Cancelling does not promise refund or termination of generation.
- Only replies linked to this request's clientMessageId are accepted. An older server omitting linkage fields will time out rather than return another conversation's text. A busy shared chat can push replies beyond the bounded history page.
- Interrupted, empty and timed-out generations are errors, not successful partial completions. Send operations are not retried on transient failures; authentication gets at most one refresh retry and reuses the same clientMessageId.

## Attachment trust and expansion

Only paths explicitly authorized by app-created attachment metadata on the **latest user message** may be read. Normal sends and both queued-send paths carry this in-memory provenance in `AgentMessage.todayAttachmentPaths`. It is not reconstructed from caller-authored XML or an earlier message, and is intentionally not persisted as reusable file-read authority. Merely naming an existing file in `<user-attached-files>` does not authorize it.

The production entry point shares mutable authorization and byte accounting across every text part in the current turn:

```swift
static func expandingAttachments(
    in text: String,
    uploadsDirectory: URL,
    authorizedPaths: inout Set<String>,
    accumulatedBytes: inout Int
) throws -> String
```

A fixture/single-value convenience overload also requires explicit authorization:

```swift
static func expandingAttachments(
    in text: String,
    uploadsDirectory: URL,
    authorizedPaths: Set<String>
) throws -> String
```

There is no unauthenticated two-argument overload. Do not use the copying convenience overload once per production text part: that would reset both consumed authorizations and the shared byte budget.

- **Every block, in order:** all current-turn XML index blocks are expanded, not just the first block. Text before, between and after them is preserved. Each replacement contains compact JSON with the file's name and UTF-8 content, with file contents explicitly presented as data rather than instructions. XML-like text inside a file remains inert data; it is not recursively expanded. This labeling is not a guarantee against model prompt injection.
- **One authorization per match:** an XML attribute is decoded and matched against the exact full authorized Linux path under `/var/minis/attachments/uploads/`. A successful match removes that path from the shared set before any file access. Basenames, Minis URLs, another existing file, an encoded spelling instead of the actual path, and duplicate references do not grant additional authority. A duplicate in another block or text part fails closed. Generate XML attributes with `TodayTextAttachmentContext.escapedAttribute`; authorize the actual unescaped path, not the escaped attribute value.
- **Bounded local reads:** only supported extensions and regular files directly inside the resolved session upload directory are accepted. Traversal, nested paths, symlinks and special files are rejected. The reader uses `openat` with `O_NOFOLLOW`, validates and reads the same descriptor, and bounds the actual bytes read rather than trusting the XML `size` attribute. Oversized, missing, invalid UTF-8 or NUL-containing files are explicit errors; there is no silent truncation or successful path-only submission.
- **Shared limits:** the inclusive per-file and per-turn limits are 128 KiB and 256 KiB respectively. Accounting uses actual UTF-8 bytes across all current-turn files, XML blocks and queued text parts, not string character counts. Two 128 KiB files fit; one extra byte exceeds the total limit. Files each below the per-file limit can still exceed the aggregate limit.
- **History is omission-only:** earlier user and assistant text has every attachment index replaced with an omission marker, without reading those files. This also applies to missing, unsupported or unsafe historical references. To analyze an old file again, attach it to the current turn again. Historical image data is omitted; a current image is rejected.
- **Final request budget:** after expansion and history stripping, `TodayAgentProvider` estimates the complete outgoing text and system prompt with `ContextSizeMeter.estimateTokens`. It reserves requested output tokens plus 1,024 context tokens and applies the input safety factor before any upstream call. A request under both file-byte limits can still exceed the model context budget and fail locally.

## Offline regression checks

Run from the repository root; no live account or network access is required:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_today_provider.py --static-only
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_today_protocol.py
# Required-toolchain CI / a machine with swiftc:
PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_today_protocol.py --require-swift
```

The static suite checks wiring, explicit authorization on both helper overloads, single-use authorization before reads, shared inout state, normal and queued-send provenance, the final context guard, and fixture manifest/extraction integrity. It is not a Swift typecheck, runtime test or service compatibility test.

The protocol harness declares **66 Swift fixtures**. It compiles the complete, unmodified `TodayProvider.swift` together with the actual final `private struct TodayAgentProvider` extracted byte-for-byte from `AIChatViewModel+ProviderFactory.swift`. Extraction verifies a unique declaration and its closing boundary at the end of the factory; unexpected trailing declarations fail rather than being silently ignored. Source hashes are printed and both source files are checked for drift during execution. Access levels and production logic are not rewritten.

Only application dependencies are stubbed, including the minimal agent/model types and a deterministic `ContextSizeMeter` stand-in. Budget fixtures exercise the real adapter's guard with clearly over/under-budget inputs; they do **not** validate the production tokenizer/estimator's numeric accuracy. Every URLSession request is intercepted locally, including unknown requests: a mismatch or exhausted fixture queue fails closed instead of falling through to the network.

Attachment fixtures cover bounded JSON extraction without parsing trailing user text, Unicode/quoting, multiple and adjacent blocks, multiple files, explicit authorization and forged references, exact and consumed paths across blocks/parts, XML-escaped filenames, per-file and aggregate boundaries, real-agent shared budgets, final context checks, history-only omission, symlinks, directories, malformed indexes, unsupported files, missing files, invalid UTF-8 and NUL bytes. Existing canonical protocol, token, model, polling, cancellation and account-gate fixtures remain in the same suite.

Exit status is part of the contract:

- `0`: all declared Swift fixtures compiled and passed, with the exact expected run count and no source drift.
- `77`: `swiftc` is unavailable; **SKIP, zero Swift fixtures executed**, not a runtime success.
- With `--require-swift`, a missing compiler exits `1` instead of `77`. Compiler errors, failed/incomplete fixtures, extraction errors and source drift also fail with `1`.

A green static suite plus a skipped Swift suite is **not** evidence that the provider or real agent adapter compiles. Run `--require-swift` on a Swift-enabled machine, then complete a full Xcode build and separately authorized live-account testing before declaring the integration usable.

## Protocol evidence

Reviewed publicly available source, not a live authenticated account:

- https://github.com/jzPPP3333/cpa-today-plugin/blob/18d79b87bd077b8cb72468bf304d9cdfdb7d866b/internal/today/client.go
- https://github.com/misakano7545/today2api-panel/blob/2bf5c326d2a8767010db48e73a7e06966343a3bc/internal/today/chat.go
- Official public JS, fetched 2026-11-27: `https://todayai.cn/_next/static/chunks/0tldm70om_pw8.js` (schemas), `3p95iox45q78p.js` (JWT), `2_67k-6n7ot63.js` (model options). Asset names are not stable protocol guarantees.

Public unauthenticated probes reached the token/pricing/history authentication gates, but **do not validate authenticated response compatibility or successful chat**. Fixture tests validate our encoding/decoding, not upstream availability. Full Xcode compilation and a separately authorized live-account test are required before declaring the integration usable.
