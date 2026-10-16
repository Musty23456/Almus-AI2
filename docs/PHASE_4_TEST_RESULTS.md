# Phase 4 test results

Run on 15 Oct 2026 in the build sandbox (Node 22, no network, no Flutter SDK). Raw output: `PHASE_4_BACKEND_TEST_OUTPUT.txt`.
**No live provider API was called by any test.** Providers are mocked adapters or a stubbed `fetch`.

## Executed

| Suite | Result |
|---|---|
| Backend `node --test` (all files) | **105 / 105 pass** (104 tests + 1 shared helper file `testkit.test.js` that the runner counts), about 1.7 s |
| Python tool tests (`tool/`) | **21 / 21 pass** (unchanged from Phase 3) |
| Production file layout boot (Dockerfile contents, no tests) | Started with only `GROQ_API_KEY` set; `/health` and an authenticated `/v1/providers` answered correctly |

Backend by file:

| File | Tests | Covers |
|---|---|---|
| `validate.test.js`, `gemini.test.js`, `server.test.js` (Phase 2/3) | 18 + 12 + 17 = 47 | All still pass through the new orchestrator path. The Gemini client was changed additively and `server.test.js`/`gemini.test.js` were **not modified**. |
| `ai.orchestrator.test.js` (new) | 27 | Mocked adapters: routing, retries, backoff, fallback rules, privacy, health |
| `ai.adapters.test.js` (new) | 15 | HTTP status classification, Groq/OpenRouter/Gemini adapters (request shape, parsing, model filtering), backoff, health tracker, redaction |
| `server.providers.test.js` (new) | 15 | Real HTTP server + stubbed upstreams: end-to-end routing, endpoints, auth, rate limits, secrets, cancellation, config validation |

### Requirement checklist (section 8 of the brief)

| Required scenario | Where it is tested |
|---|---|
| Successful requests | orchestrator "successful request goes to the primary provider only"; server "default request (no routing)" |
| Rate limits | orchestrator "rate limit: waits at least Retry-After…", "…very long Retry-After is not waited for", "own requests-per-minute budget"; adapters "classifyOpenAIError maps every important status" |
| Quota exhaustion | orchestrator "quota exhaustion is never retried"; adapters "Gemini… per-day quota recognised"; server "Gemini quota exhausted + fallback OFF/ON" |
| Timeouts | orchestrator "timeout is retried only when the provider is free-only"; adapters "transport failures: timeout…" |
| Invalid credentials | orchestrator "invalid credentials: no retry, provider becomes misconfigured…"; server "POST /v1/providers/check… misconfigured" |
| Provider outages | orchestrator "outage and recovery"; "503 retried, 500 not"; server "recovery after an outage over HTTP" |
| Unsupported capabilities | orchestrator "unsupported capability…", "context limits…" |
| Fallback behaviour | orchestrator: allowed-only providers, operator exclusion, memory withheld, attachments never shared without consent, paid fallback refused, content-blocked never forwarded, all-fail message; server: Groq rescues Gemini, undeclared-cost fallback refused |
| Disabled fallback | orchestrator "disabled fallback: nothing is sent to another provider…"; server "fallback OFF" |
| Recovery after an outage | orchestrator "outage and recovery"; "fallback keeps working while primary cools down"; server "recovery over HTTP" |

Also covered: retry bounds (per provider and total), cancellation (orchestrator and real client disconnect), user-selected
model validation against the live list, free-only enforcement for paid models, secret redaction in responses and logs even when the
upstream echoes keys, strict `routing` validation, token requirement on every new endpoint, separate rate limit for checks,
configuration validation (https-only URLs, credentials in URLs, missing keys).

## Written but NOT executed (no Flutter SDK)

| File | Tests |
|---|---|
| `test/provider_info_test.dart` | 7 |
| `test/routing_preferences_test.dart` | 7 |
| `test/backend_client_providers_test.dart` | 9 |
| `test/provider_routing_chat_test.dart` | 5 |
| `test/ai_providers_screen_test.dart` | 10 (widget tests) |
| `test/local_operations_offline_test.dart` | 2 |

Total 40. I checked them by reading against the real APIs of the controllers they use (constructor and method names were
verified in the source), by a delimiter-balance scan of every Dart file, and by checking that each scripted edit applied.
**That is not compilation.** Expect to fix some compile errors or small assertion mismatches on first `flutter test`.
`test/widget_test.dart` was edited (version string `0.11.0` → `0.12.0`); all other Phase 1-3 Dart tests are unchanged.

## Not tested at all

* Any real provider (Gemini, Groq, OpenRouter) over the network: error body shapes, current models, real limits.
* The app on a device or emulator, and the provider settings screen visually.
* The Docker build; the GitHub Actions APK build.
