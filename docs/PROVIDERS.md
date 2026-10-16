# AI providers: configuration guide (Phase 4)

ALMUS AI no longer depends on one AI service. The **backend** talks to providers through small adapters and an
orchestrator; the phone app only sends the user's routing choices and shows status. **All provider keys live on the
backend**, never in the Flutter code, assets or APK.

```
phone app ──HTTPS + app token──► backend ──► orchestrator ──► Gemini adapter ──► Google
 (routing prefs, no provider keys)             │ health, retries, ├► Groq adapter   ──► Groq
                                               │ fallback rules   ├► OpenRouter     ──► OpenRouter ─► model hosts
                                               │                  └► any OpenAI-compatible adapter
```

## 1. What was researched, and what that means for the code

Researched on **15 Oct 2026** from the providers' own documentation. These facts change; **re-check before relying
on them.** The code deliberately contains none of the numbers below.

| Topic | Finding (source) | Consequence in the code |
|---|---|---|
| **Free tiers are not permanent or uniform** | Third-party "free LLM API" sites disagreed about Groq's free limits by more than 10× (hundreds vs thousands of requests/day). Groq's own page says limits are per model, per organisation, and may vary. | No quota or "free forever" assumption is built in. Operators declare cost (`*_COST_POLICY`); the app says "as declared by your server". |
| **Groq** (`console.groq.com/docs/rate-limits`, `/docs/api-reference`, `/docs/your-data`) | OpenAI-compatible at `https://api.groq.com/openai/v1`. Limits are per model: requests/min, requests/day, tokens/min, tokens/day. On HTTP 429 a `retry-after` header is sent. The page I read listed small free-plan tokens-per-minute caps (8K for some chat models), which long requests can exceed. Its `/models` list also contains speech, TTS and guard models. Inference data is not retained by default but may be logged up to 30 days for reliability/abuse unless Zero Data Retention is enabled; processing is in the US. Its own doc examples cite model IDs that have since been retired. | Models are discovered live (`GET /models`), non-chat models are filtered out, no default model is hardcoded. A per-provider `GROQ_MAX_INPUT_TOKENS` cap lets small plans skip requests that would be rejected. 429s are split into per-minute (retry) and per-day (no retry). |
| **OpenRouter** (`openrouter.ai/docs/api-reference/limits`, models API, provider routing, privacy/logging) | One key reaches many models and upstream hosts; some are free (`:free`, price `0`), most are paid. Free models are limited per minute and per day, and the daily allowance depends on credits ever purchased. HTTP 402 = out of credits. `GET /api/v1/key` validates a key and shows free-request counters. `GET /api/v1/models` returns `pricing`, `context_length`, `architecture.input/output_modalities`. Request option `provider.data_collection: "deny"` asks to avoid hosts that may store prompts. Each upstream host has its own logging/training policy. | **Paid models are blocked unless `OPENROUTER_ALLOW_PAID=true`**: a model is usable only if the live price list says prompt and completion cost `0`; unknown price = not allowed. 402 is never retried. `data_collection: deny` is sent by default. |
| **Gemini** (`ai.google.dev/gemini-api/docs/rate-limits`) | Limits are per Google project and per model, visible only in AI Studio; free tier availability and limits vary and can change. A 429 can mean a per-minute limit **or** a per-day quota (the error details name the quota). | The existing Gemini client was kept. A daily quota (recognised from the error details) is classified `quota_exhausted` and is never retried; per-minute limits honour `Retry-After`. |
| **Licensing** | Using these services is governed by each provider's terms and your account; this code is a client. The backend has no runtime dependencies. | Nothing in this repository grants rights to any provider. Read each provider's terms. |
| **Modalities** | All three accept text. Some models accept images, but the app never uploads images or files (it sends only text extracted on the phone). | Every adapter declares `images: false`. Capability-aware routing exists and is tested with a mock that supports images, but no real adapter claims it. |

Not verified by me: pricing pages, exact current free-plan numbers, and whether any specific model name is available
to **your** key today. That is what the live `/models` calls and the **Check connections** button are for.

## 2. Providers in this release

| Id | Adapter | Enabled by | Notes |
|---|---|---|---|
| `gemini` | `ai/adapters/gemini.js` (wraps the verified Phase 2/3 client) | `GEMINI_API_KEY` | Default primary provider. Keeps its optional `GEMINI_FALLBACK_MODEL`. |
| `groq` | `ai/adapters/openaiCompat.js` | `GROQ_API_KEY` + a model (or `auto`) | OpenAI-compatible. |
| `openrouter` | same factory | `OPENROUTER_API_KEY` + a model (or `auto`) | Free models only unless `OPENROUTER_ALLOW_PAID=true`. |
| `compat` (any id you choose) | same factory | `OPENAI_COMPAT_BASE_URL` + `OPENAI_COMPAT_API_KEY` | For any other OpenAI-compatible service (Cerebras, Mistral, Together, a self-hosted Ollama...). I did **not** research those services; configure and check them yourself. |

At least one provider must be configured. A Gemini-only setup behaves exactly as before.

## 3. Environment variables

Set them in your host's dashboard (for example Render) or a local `.env` that you never commit. `Backend/env.example`
lists them all with safe placeholders.

### Routing and safety

| Variable | Default | Meaning |
|---|---|---|
| `AI_PRIMARY_PROVIDER` | `gemini` | Provider used when the app does not choose. If not configured, the first configured provider is used. |
| `AI_FALLBACK_ORDER` | (configured order) | Comma list, tried in this order **only when the user allowed fallback**. |
| `AI_FALLBACK_ALLOW_PAID` | `false` | If false, a provider whose cost is not `free_only` is never used as a fallback. |
| `AI_ALLOW_USER_MODEL_SELECTION` | `true` | Let the app choose a model from the provider's live list. |
| `AI_MAX_ATTEMPTS_PER_PROVIDER` | `2` (1-3) | Attempts on one provider (first try + retries). |
| `AI_MAX_TOTAL_ATTEMPTS` | `4` (1-8) | Hard cap across all providers for one request. |
| `AI_BACKOFF_BASE_MS` / `AI_BACKOFF_CAP_MS` | `400` / `4000` | Exponential backoff with full jitter. |
| `AI_MAX_RETRY_WAIT_MS` | `5000` | Never wait longer than this for a retry; fail over or report instead. |
| `AI_REQUEST_DEADLINE_MS` | `50000` | Total time budget for one chat request (including retries and fallbacks). |
| `AI_BREAKER_THRESHOLD` / `_BASE_MS` / `_MAX_MS` | `3` / `15000` / `120000` | Circuit breaker: after N consecutive failures a provider is skipped for a growing cool-down. |
| `AI_QUOTA_COOLDOWN_MS` | `900000` | Cool-down after quota exhaustion when the provider gives no reset time. |
| `CHECK_RATE_LIMIT_PER_MINUTE` | `6` | Per-client limit on health checks and model-list calls (they contact providers). |

### Per provider

| Variable | Meaning |
|---|---|
| `GEMINI_BILLING` | `free`, `paid` or `unknown` (default). The server cannot know your billing; `free` makes Gemini `free_only`. |
| `GROQ_MODEL`, `OPENROUTER_MODEL`, `OPENAI_COMPAT_MODEL` | Exact model id, **or** `auto` (pick from the live list: usable models only, largest context first). **No default is built in.** Empty = "no model selected" until the user picks one in the app. `auto` can change over time: pin a model for stability. |
| `GROQ_COST_POLICY`, `OPENAI_COMPAT_COST_POLICY` | `free_only`, `metered` or `unknown` (default). You declare what your key costs. |
| `OPENROUTER_ALLOW_PAID` | `false` (default): only models priced at zero. `true`: paid models are allowed and the provider is `metered`. |
| `OPENROUTER_DATA_COLLECTION` | `deny` (default) asks for hosts that do not collect data, which can reduce available models; `allow` removes the restriction. |
| `*_FALLBACK_ELIGIBLE` | `true` (default). `false` = never used as a fallback, whatever the user ticks. |
| `*_MAX_INPUT_TOKENS` | Optional cap, for example to stay under a small tokens-per-minute limit. Requests estimated above it skip that provider (the message is not sent). |
| `*_RPM_LIMIT` | Optional self-imposed requests per minute. |
| `*_BASE_URL` | Defaults to the provider's documented URL. Must be `https://` (plain `http://` only for localhost), no credentials, query or fragment. Redirects are never followed. |
| `OPENAI_COMPAT_ID`, `_NAME`, `_KEY_OPTIONAL` | Id and display name of the generic provider; `KEY_OPTIONAL=true` allows no key but only for a localhost address. |

### Why a fallback can be refused even after the user allowed it

Three independent gates must all pass, so a single mistake cannot send content somewhere unexpected:
1. **The user** enabled fallback and ticked that provider (app settings, off by default).
2. **The operator** left `*_FALLBACK_ELIGIBLE=true` for it.
3. **Cost**: the provider is `free_only`, or the operator set `AI_FALLBACK_ALLOW_PAID=true`.

For example, with `GROQ_COST_POLICY` left at `unknown`, Groq will **not** be used as a fallback; set it to `free_only`
only if you have confirmed your Groq key is on a free plan.

## 4. How a request is handled

1. Validate the body, including the optional `routing` object (strict: unknown fields are rejected).
2. Pick the **primary** provider: the user's choice, else `AI_PRIMARY_PROVIDER`.
3. Try it. Decide by **error category** (table below): retry, fail over, or stop.
4. If fallback is allowed by all three gates, try the next provider with the **minimum content**: memory notes are
   omitted unless the user allowed them; if the user attached files and did not allow sharing file text, the fallback is
   **skipped** (answering without the file would be wrong).
5. If nothing works, return one clear error that names which providers failed and why (categories only, no upstream text).

| Category | Typical cause | Retry same provider? | Fail over? | Effect on health |
|---|---|---|---|---|
| `rate_limited` | HTTP 429 per-minute | Yes, bounded, honours `Retry-After`, only if wait ≤ `AI_MAX_RETRY_WAIT_MS` | Yes | Cool-down until retry time |
| `quota_exhausted` | Daily/monthly quota | **No** | Yes | Long cool-down |
| `timeout` | No answer in time | Only for providers declared `free_only` (a retry could be billed twice) | Yes | Counts toward breaker |
| `unavailable` | HTTP 5xx | 503/529: yes. 500/502/504: only if `free_only` | Yes | Counts toward breaker |
| `network` | Connection failed | Only if `free_only` | Yes | Counts toward breaker |
| `auth` | Bad key | **No, never** | Yes | `misconfigured`, **sticky** (needs operator fix + explicit check) |
| `payment_required` | No credit (402) | **No, never** | Yes | Long cool-down |
| `model_not_found` | Model retired/unknown | No | Yes | `misconfigured` |
| `context_too_large` | Request too big | No | Yes (to a larger provider) | None |
| `bad_request`, `invalid_response`, `unknown` | Misc | No | Yes | Failure / none |
| `content_blocked` | Provider safety filter | No | **No** (would sidestep the filter) | None |
| `cancelled` | App closed/aborted | No | No | None |

Retries use exponential backoff with **full jitter** and are capped three ways: per provider, per request, and by a
total time deadline. Closing the app (client disconnect) aborts the in-flight upstream call and any pending retry
(the upstream may still finish or bill the request it already received; cancellation cannot recall it).

## 5. Provider status and health

`GET /v1/providers` reports what is known and **makes no provider call**. A configured provider that nothing has
confirmed is `unknown` / `verified: false`. Only a real check (`POST /v1/providers/check`, the app's **Check
connections** button) or a successful real chat marks it `healthy` / `verified: true`.

States: `unconfigured`, `unknown`, `healthy`, `degraded` (cool-down over, recovery unconfirmed), `rate_limited`,
`quota_exhausted`, `unavailable` (breaker open), `misconfigured`.

Checks call the provider's key/model-list endpoint (OpenRouter: `GET /key`), not a generation, so they should not
consume generation quota, but providers may rate-limit even those calls. A successful key check does not prove
quota is free, so an active rate/quota cool-down is kept.

## 6. Backend API additions

All need `Authorization: Bearer <APP_ACCESS_TOKEN>` (unless you set `ALLOW_UNAUTHENTICATED=true` for local tests).

| Endpoint | Purpose |
|---|---|
| `POST /v1/chat` | Optional `routing`: `{"provider":"<id>","models":{"<id>":"<model>"},"fallback":{"enabled":true,"providers":["<id>"],"shareMemory":false,"shareAttachments":false}}`. Response adds `provider`, `providerName`, `processing:"remote"`, `route{fallbackUsed, failed[], omitted[], attempts, modelSource}`. |
| `GET /v1/providers` | Status of every provider (no upstream call). |
| `POST /v1/providers/check` | Body `{}` or `{"provider":"<id>"}`: real health checks. Limited by `CHECK_RATE_LIMIT_PER_MINUTE`. |
| `GET /v1/providers/<id>/models` | The provider's live list of models this server may use. |
| `GET /health` | Adds `aiConfigured` (credentials exist; **not** "works"). `geminiConfigured` is unchanged. |

New error codes: `all_providers_failed`, `provider_needs_model`, `provider_not_configured`, `unknown_provider`,
`unknown_model`, `model_not_allowed`, `model_unverified`, `invalid_routing`, `context_too_large`,
`unsupported_capability`, `fallback_blocked_by_privacy`, `upstream_payment_required`, `cancelled`. Error objects may
carry `details` (`attempts`, `skipped`, `fallbackSuggested`: categories and provider ids only).

## 7. Adding another provider

No chat code changes are needed.

* **OpenAI-compatible service**: set the four `OPENAI_COMPAT_*` variables. Done.
* **Different protocol**: write one file that exports a factory returning an object with this contract, and register it
  in `buildProviders` (`ai/registry.js`) or pass it to `createApp({ providers: [...] })`:

```js
{
  id, displayName, kind, configured, configuredModel, costPolicy,     // 'free_only' | 'metered' | 'unknown'
  fallbackEligible, capabilities: { text, systemPrompt, extractedTextAttachments, images, streaming },
  limits: { maxInputTokens, rpmLimit },  docsUrl?, dataNote?, limitsNote?,
  isModelAllowed(model), pickAutoModel(models),
  fetchModels({ signal }),      // live model list -> [{ id, name, contextTokens, maxOutputTokens, free }]
  check({ signal }),            // real key/health check
  generate(request, { model, signal, timeoutMs })   // -> { reply, model, finishReason, usage }
}
```

Translate every upstream failure into a `ProviderError(category, { status, retryAfterMs, safeToRetry })`; never put
upstream text in it. `assertProvider()` checks the contract at start-up, and `testkit.test.js` has a scriptable mock you
can copy for tests.

## 8. Security

* Keys exist only in backend environment variables. They are sent only in the `Authorization` header of HTTPS requests
  to the provider's own base URL; never in URLs, request bodies, logs, responses or the phone app.
* Every log line passes through a redactor (exact configured secrets plus key-shaped patterns). Message text is never logged.
* Clients receive only fixed message templates, provider display names and error categories. Upstream error bodies and internal
  exceptions are never forwarded. Anything unexpected becomes a generic `500`.
* `routing` is strictly validated; a user-selected model must appear in the provider's live list and, for free-only
  providers, be priced at zero (a tampered client cannot select a paid model).
* Provider health checks and model lists have their own tight per-client rate limit.
* `APP_ACCESS_TOKEN` is the only credential the phone holds. It is stored in the app's private preferences in plain text
  (Phase 1 limitation, see `KNOWN_LIMITATIONS.md`). Anyone who extracts it can use your backend quota until you rotate it.
  Use a long random value (the server warns under 16 characters).

### User-supplied API keys: not implemented, by design

The task allowed this as optional. I chose **not** to add it:

* A key entered on the phone must be stored on the phone. Without a hardware-backed store (for example Android Keystore via
  `flutter_secure_storage`, a new dependency I cannot compile-test here) it would be plaintext, and even a secure store
  can be read on a rooted device or by malware.
* The key must then be sent to the backend on every request, making the backend a proxy for arbitrary third-party keys:
  new leakage, logging, abuse and SSRF surfaces.
* Centrally managed server keys avoid all of that and are what this phase implements.

If you add it later: use a hardware-backed store; send the key per request over HTTPS in a header (never body/URL); never
persist or log it server-side (the redactor already masks key-shaped strings); restrict it to the known provider ids; and
document that a compromised phone exposes the key.

## 9. Local versus remote

| Remote (needs a provider) | Always local (works with every provider down) |
|---|---|
| Producing a chat reply | Opening, listing and searching saved conversations |
| | Reading, adding, editing memory |
| | Backup export / import |
| | Parsing attached documents (text is extracted on the phone) |
| | App settings, lock, provider settings screen |

The app does not currently include local calculators or other deterministic text tools, so there was nothing of that
kind to preserve; none was invented.
