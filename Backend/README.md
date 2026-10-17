# ALMUS AI Backend

A small, dependency-free Node.js service (Node 20+) that sits between the ALMUS AI Android app and the Gemini API.
Your Gemini API key lives only in this server's environment variables. It is never in the app, the APK, or GitHub.

## Endpoints

### `GET /health`
Public. Returns `{ "status": "ok", "model": "...", "geminiConfigured": true, "authRequired": true }`. No secrets.

### `POST /v1/chat`
Header: `Authorization: Bearer <APP_ACCESS_TOKEN>` and `Content-Type: application/json`.

```json
{ "messages": [
  { "role": "user", "content": "Hello" },
  { "role": "assistant", "content": "Hi! How can I help?" },
  { "role": "user", "content": "Explain recursion simply" }
] }
```
Success `200`:
```json
{ "reply": "...", "model": "gemini-...", "finishReason": "STOP",
  "usage": { "promptTokens": 12, "outputTokens": 80, "totalTokens": 92 } }
```
Optional field (Phase 4): `"memoryContext": "..."`, a short block of the user's personal memory notes picked on their phone. It is cleaned, limited to `MAX_MEMORY_CHARS` (default 3000, else `400 memory_too_long`) and appended to the system instruction, never to the conversation. It is not logged or stored. Omit it for no memory.

Rules: the last message must be `user`; roles are `user` or `assistant`; each message at most `MAX_MESSAGE_CHARS`; request body at most `MAX_BODY_BYTES`. Only the newest messages that fit `MAX_CONTEXT_CHARS` are sent to Gemini.

### `GET /v1/models`
Needs the token. Lists model names your key can use with `generateContent`, plus the configured model. Handy for choosing `GEMINI_MODEL`.

### Phase 4: providers and routing
`POST /v1/chat` accepts an optional `routing` object and reports which provider answered; `GET /v1/providers`,
`POST /v1/providers/check` and `GET /v1/providers/<id>/models` expose provider status. Gemini, Groq, OpenRouter and any
OpenAI-compatible service are supported; fallback to another provider only happens if the user allowed it. Everything
(env variables, error categories, retry rules, adding a provider) is in `../docs/PROVIDERS.md`.

### Errors
Always `{ "error": { "code": "...", "message": "...", "retryAfterSeconds": 12 } }`.

| HTTP | code | Meaning |
|---|---|---|
| 400 | `invalid_request`, `invalid_json`, `message_too_long`, `memory_too_long` | Bad request body |
| 401 | `unauthorized` | Missing/wrong access token |
| 413 | `payload_too_large` | Body bigger than `MAX_BODY_BYTES` |
| 415 | `unsupported_media_type` | Not `application/json` |
| 422 | `blocked` | Gemini declined to answer |
| 429 | `rate_limited`, `daily_limit_reached`, `quota_or_rate_limit` | Backend limit, or a provider's rate limit / quota |
| 422 | `context_too_large`, `unsupported_capability` | No allowed provider can take this request |
| 502 | `upstream_unreachable`, `upstream_auth`, `model_not_found`, `invalid_upstream_response`, `empty_response`, `upstream_bad_request`, `upstream_error` | Problem talking to Gemini |
| 503 | `server_not_configured`, `upstream_unavailable`, `all_providers_failed`, `provider_needs_model` | Missing env vars / providers down |
| 504 | `upstream_timeout` | Gemini took longer than `UPSTREAM_TIMEOUT_MS` |

Error messages never contain your API key, access token or message text, and request bodies are never logged.

## Environment variables
See `env.example` for every name. The important ones:

| Name | Required | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | yes | Your Google AI Studio key |
| `APP_ACCESS_TOKEN` | yes | A long random string you invent. The app sends it; strangers cannot use your quota |
| `MAX_MEMORY_CHARS` | no (default 3000) | Largest `memoryContext` accepted |
| `GEMINI_MODEL` | no (default `gemini-flash-latest`) | Model used for chat |
| `GEMINI_FALLBACK_MODEL` | no | Tried automatically on quota/availability errors |
| `RATE_LIMIT_PER_MINUTE` / `DAILY_REQUEST_LIMIT` | no | Abuse protection; the daily cap protects your free quota |
| `TRUST_PROXY` | set `true` on hosts | Reads the client address from the hosting proxy |

## Changing the model
Model names change over time and quotas differ per account, so nothing is hardcoded.
1. Open `https://YOUR-BACKEND/v1/models` with your token (or use the app's Settings → Test connection) to see names your key supports.
2. Check your limits at https://aistudio.google.com/rate-limit and the model list at https://ai.google.dev/gemini-api/docs/models.
3. Change `GEMINI_MODEL` in the hosting dashboard and redeploy/restart. No code change or new APK is needed.

`gemini-flash-latest` is a Google alias that follows the newest Flash model. It is convenient but can change behavior when Google updates it; pin an exact name if you want stability. Older model families are retired on a schedule, so a `model_not_found` error usually means you should pick a newer name.

Free-tier quota, availability and pricing depend on Google's current policy and your account, and can change. This project does not assume any model stays free. Also note that Google's terms for the free tier may allow your prompts to be used to improve their products; do not send sensitive information while on the free tier.

## Deploy on Render (free web service)
1. Put these files in a new **private** GitHub repo (for example `Almus-AI-Backend`). Upload the files directly into the repo root.
2. On https://render.com choose **New → Web Service**, connect the repo.
3. Settings: Runtime **Node**, Build command `npm install`, Start command `npm start`, Instance type **Free**.
4. Under **Environment**, add `GEMINI_API_KEY`, `APP_ACCESS_TOKEN`, `TRUST_PROXY=true` (and optionally `GEMINI_MODEL`).
5. Deploy. Your URL looks like `https://almus-backend-xxxx.onrender.com`. Open `/health` to check.

Free instances on Render typically sleep after a period of no traffic, so the first request after a pause can take up to about a minute. Check Render's current free-plan terms.

Other hosts work too: the included `Dockerfile` runs on Google Cloud Run, Fly.io, Koyeb and similar. Set the same environment variables and listen on `PORT`.

## Run and test locally
```
node --test                 # no install needed, no network used
GEMINI_API_KEY=... APP_ACCESS_TOKEN=test npm start
```

## Phase 4 note
If you set your own `SYSTEM_PROMPT`, it replaces the default prompt that tells the model it has no memory except the notes provided. The memory block sent by the app repeats that rule, so memory still works, but consider keeping a sentence like it in your prompt.


## Attachments (service 0.3.0)
`POST /v1/chat` accepts an optional `attachments` array: `[{ "name": "report.pdf", "kind": "pdf|docx|xlsx|csv|text|markdown", "text": "...", "truncated": false }]`.
The app sends only text it extracted on the phone. Files, images, device paths, URIs or any other field are rejected with 400
(`invalid_attachment`, `unsupported_attachment`). Limits (env): `MAX_ATTACHMENTS=5`, `MAX_ATTACHMENT_CHARS=30000`,
`MAX_ATTACHMENT_TOTAL_CHARS=60000`, `MAX_BODY_BYTES=400000`. The text is appended to the newest user message between
`BEGIN/END ATTACHED FILE` lines and the model is told to treat it as data, not instructions. Attachment text is never logged.
The response gains `attachmentsUsed`.

## Phase 6b: cloud face verification (optional, Luxand.cloud)

Routes (all need `Authorization: Bearer <APP_ACCESS_TOKEN>`; they are refused if no token is configured):

| Method | Path | Body | Result |
|---|---|---|---|
| GET | `/v1/face/status` | none | `{available, calibrated}` |
| POST | `/v1/face/person` | `{photo}` (base64 JPEG) | `{uuid}` |
| POST | `/v1/face/person/:uuid/photos` | `{photo}` | `{added:true}` |
| POST | `/v1/face/person/:uuid/verify` | `{photo}` | `{verified}` (+ `similarity` only if `FACE_RETURN_SCORE=true`) |
| DELETE | `/v1/face/person/:uuid` | none | `{deleted:true}` or an error (never a false "deleted") |

Rules built in: the Luxand token never leaves the server; no real name is sent (a random label is used);
verify is disabled until `LUXAND_MIN_SIMILARITY` is set; any answer from Luxand that is not understood is "not verified";
nothing about photos, uuids or scores is logged.

Not verified against a real Luxand account yet: the exact response field (`similarity`) of the verify call and the
delete endpoint (`DELETE /person/{uuid}`). Make one real call each before relying on them.
