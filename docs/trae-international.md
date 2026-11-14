# Trae international provider

OpenMinis now exposes **Trae 国际版** as its own provider type while keeping
the legacy **Trae** type unchanged for existing configurations.

Both providers use Trae's private IDE account protocol. They are unofficial
integrations, require an account that already has model access, and do not add
a subscription or quota. They are text-only.

| Provider | Chat origin | Sign-in behavior |
| --- | --- | --- |
| Trae | `https://trae-api-cn.mchost.guru` by default | Legacy automatic behavior retained |
| Trae 国际版 | `https://coresg-normal.trae.ai` by default | Explicit Trae international sign-in |

## Network contract

- Chat: `POST /api/agent/v3/llm_utils_chat` (not OpenAI's
  `/chat/completions`).
- Model directory: `GET /api/remote/v1/models?functions=…` on the SOLO web
  directory (the roster the vendor's own picker renders), asking every chat
  function (`solo_work_remote`, `solo_work_lite`, `solo_agent_remote`,
  `chat_v3`, `solo_coder`) and unioning the groups in that priority order.
  `POST /api/ide/v1/get_detail_param` is still asked for the per-function
  metadata the directory does not publish, and fills in anything the web
  directory omits.
- The directory-resolved `function` is echoed in the chat body so a model is
  routed to the roster that published it.
- **Auto** is not a `config_name`: it is the `inline_chat` scene with `model`
  and `config_name` omitted, and the server picks. Sending `"auto"` in either
  field is rejected, which is why the row is pinned in the model list rather
  than taken from the roster.
- The access token is sent in all three places required by Trae:
  `Authorization: Cloud-IDE-JWT …`, `X-Ide-Token`, and `X-Cloudide-Token`.
- Responses use Trae's `output`, `token_usage`, `done`, and `error` events and
  are normalized before the existing agent parser sees them.

## Account handling

- International sign-in discovers its login host through `GetLoginGuidance`,
  uses PKCE, and exchanges the authorization code with a real P-256 device
  public key.
- The gateway that successfully exchanges a token is stored and validated
  before refresh; a saved China credential is never sent as an explicit
  international credential.
- OAuth gets one 401-triggered forced refresh per request. Pasted manual
  tokens are left alone.

## Regression tests

CI compiles the real `TraeAPI.swift` and `TraeStreamDialect.swift` with an
isolated harness:

```sh
swiftc -O \
  -o build/trae-international-tests/trae-tests \
  src/ios/Providers/Trae/TraeAPI.swift \
  src/ios/Providers/Trae/TraeStreamDialect.swift \
  scripts/trae-international-tests/Support.swift \
  scripts/trae-international-tests/main.swift
./build/trae-international-tests/trae-tests
```

The tests are offline: model directory traffic is intercepted with
`URLProtocol`, and no account or credential is used.
