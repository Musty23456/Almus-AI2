# ALMUS AI — Phase 4 Report: Multi-provider AI orchestration and fallback

Input: verified Phase 3 project (0.11.0+11). Output: 0.12.0+12 (backend 0.4.0), one complete ZIP.
Gemini remains the default and its integration is preserved.

## 1. Honest status (read first)

| Check | Result |
|---|---|
| Backend tests (`node --test`) | **105 / 105 pass** (47 inherited from Phase 3, all unmodified, plus 57 new; plus 1 helper file the runner counts) |
| Live provider calls | **None.** Every test uses mocked adapters or a stubbed `fetch`. Real Groq/OpenRouter behaviour is untested |
| Flutter / Dart | **Not compiled, not run** (no SDK). ~1,000 lines of new Dart (plus edits to existing files) and 40 new Dart tests are unexecuted and may contain compile errors |
| Python tool tests | 21 / 21 pass |
| Docker build | Not run (no Docker). The production file layout was booted manually and answered correctly |
| Device / emulator | Nothing run on a phone |

Details: `docs/PHASE_4_TEST_RESULTS.md`.

## 2. What was built

### Provider abstraction (`Backend/ai/`)
A provider is an object satisfying a small contract (`id`, capabilities, cost policy, `fetchModels`, `check`, `generate`),
validated by `assertProvider`. Adapters: **Gemini** (wraps the verified client; changes to it were additive), **Groq**,
**OpenRouter**, and a **generic OpenAI-compatible** adapter configured purely by environment variables. A new compatible
service needs no code; a different protocol needs one file. The chat handler (`app.js`) no longer knows any vendor.

### Orchestrator
Provider selection, capability-aware routing (images, estimated context size, per-provider input caps), fallback selection,
per-attempt timeouts under a total deadline, bounded retries, exponential backoff with full jitter that never undercuts
`Retry-After`, an own requests-per-minute budget, per-provider health with a circuit breaker, 15 error categories
mapped to retry/fallback/health policy in one table (`ai/errors.js`), and cancellation (client disconnect aborts the upstream call and pending retries).

### Your specific rules, and how they are enforced
| Rule | Implementation |
|---|---|
| No infinite retries | Per-provider (default 2) and total (default 4) attempt caps plus a request deadline |
| Don't retry permanent auth errors | `auth` never retried; provider becomes **sticky `misconfigured`** and is skipped until an operator fixes it and runs a check |
| No unexpected paid usage | 402 never retried; timeouts/5xx retried only for providers declared `free_only`; OpenRouter paid models blocked by live price (unknown price = blocked); fallback to a non-free-only provider refused unless `AI_FALLBACK_ALLOW_PAID=true`; a user cannot select a paid model by tampering |
| Respect privacy / fallback preferences | Fallback **off by default**; three gates (user ticked the provider, operator eligible, cost allowed); memory notes withheld from fallbacks unless allowed; if files are attached and not allowed to be shared, the fallback is **skipped** rather than answering without the file; provider safety refusals are never forwarded to another provider |
| Clear error when nothing is available | One error naming each provider and its category, plus `fallbackSuggested` when switching fallback on could help |
| Never imply availability unearned | `GET /v1/providers` makes no provider call and reports `unknown`; only a real check or request yields `healthy`/`verified`. The app says "Not checked yet" until then |
| No hardcoded model names | New providers have **no default model**; live `/models` lists, `auto` selection, non-chat models filtered, user choice validated against the live list |
| Secrets on backend | Keys only in env vars, only in the `Authorization` header; redactor on all logs; clients get fixed templates and categories, never upstream text; strict `routing` validation; tight rate limit on checks; redirects refused |

### App
**Settings → AI providers**: local-versus-remote explanation (and which features always work offline), provider cards
(status, model chooser from the live list, capabilities including "No images", cost and data notes, Check button), main-provider
choice, automatic-fallback switch with per-provider tick boxes and separate memory/file switches. Replies are labelled with
the provider that answered (stored `engineLabel`, e.g. `GROQ`), and a notice explains any fallback. `routing` is sent only if
the user changed something, so default requests are byte-identical to Phase 3.

### Local operations
Conversations, memory, history search, backup, document parsing and settings never call a provider (unchanged architecture;
`local_operations_offline_test.dart` asserts it with an all-providers-down engine). The app has **no** local calculator or
deterministic text tools; I did not invent any.

### Optional user-supplied keys
**Not implemented, deliberately.** The reasons and what a safe future design would need are in `docs/PROVIDERS.md` §8.

## 3. Provider research (summary; full table with sources in `docs/PROVIDERS.md`)
* Free tiers/limits are per model and account, vary, and third-party sources contradict each other: nothing is hardcoded.
* Groq: OpenAI-compatible; per-model limits; small token-per-minute caps on free chat models; model list includes non-chat models; no inference retention by default, up to 30 days of logging in some cases.
* OpenRouter: free and paid models behind one key; 402 on exhausted credit; `GET /key` for key checks; `provider.data_collection: deny` available; hosts have their own policies.
* Gemini: per-project, per-model limits; 429 may be per-minute or per-day, which this release distinguishes.
* Not researched: other OpenAI-compatible services (supported generically, unverified).

## 4. Decisions you may want to reverse
1. **Groq and unknown-cost providers are refused as fallbacks until you set `*_COST_POLICY=free_only`.** Safer, but it means fallback does nothing until you declare it.
2. **A file attachment blocks fallback** unless the user allows sharing file text.
3. **A tripped breaker blocks the primary for 15–120 s** (also with a single provider) instead of hammering it.
4. Health and model caches live in memory and reset on restart (free hosts sleep).

## 5. Risks to check first
1. `flutter pub get && flutter analyze && flutter test`: expect to fix compile/assertion issues in the new Dart code (list in `docs/PHASE_4_TEST_RESULTS.md`).
2. With real keys: `POST /v1/providers/check`, then `GET /v1/providers/groq/models`, and confirm the model names and statuses are sensible.
3. Verify real error shapes: trigger a 429 on each provider and confirm the classification (`rate_limited` vs `quota_exhausted`).
4. Confirm `GROQ_COST_POLICY` / `GEMINI_BILLING` reflect your actual plans before enabling fallback.

## 6. Files
New backend: `ai/{errors,http,backoff,health,messages,registry,orchestrator}.js`, `ai/adapters/{gemini,openaiCompat}.js`, `redact.js`,
tests `ai.orchestrator|ai.adapters|server.providers|testkit .test.js`. Changed backend: `app.js`, `config.js`, `validate.js` (routing),
`gemini.js` (additive: model override, signal, daily-quota detail, detailed model list, no redirects), `errors.js`, `index.js`, `Dockerfile`, `env.example`, `render.yaml`, `package.json`, `README.md`.
New app: `lib/ai/{provider_info,routing_preferences,provider_status_controller}.dart`, `lib/screens/ai_providers_screen.dart`, six test files.
Changed app: `backend_client.dart`, `routed_chat_service.dart`, `chat_service.dart`, `chat_controller.dart`, `chat_screen.dart`, `settings_screen.dart`, `app_shell.dart`, `app.dart`, `app_info.dart`, `pubspec.yaml`, `widget_test.dart`.
Docs: `docs/PROVIDERS.md`, `docs/PHASE_4_TEST_RESULTS.md`, `docs/PHASE_4_BACKEND_TEST_OUTPUT.txt`, updated `README.md`, `CHANGELOG.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN_LIMITATIONS.md`.
