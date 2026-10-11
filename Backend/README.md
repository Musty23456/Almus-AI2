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
Rules: the last message must be `user`; roles are `user` or `assistant`; each message at most `MAX_MESSAGE_CHARS`; request body at most `MAX_BODY_BYTES`. Only the newest messages that fit `MAX_CONTEXT_CHARS` are sent to Gemini.

### `GET /v1/models`
Needs the token. Lists model names your key can use with `generateContent`, plus the configured model. Handy for choosing `GEMINI_MODEL`.

### Errors
Always `{ "error": { "code": "...", "message": "...", "retryAfterSeconds": 12 } }`.

| HTTP | code | Meaning |
|---|---|---|
| 400 | `invalid_request`, `invalid_json`, `message_too_long` | Bad request body |
| 401 | `unauthorized` | Missing/wrong access token |
| 413 | `payload_too_large` | Body bigger than `MAX_BODY_BYTES` |
| 415 | `unsupported_media_type` | Not `application/json` |
| 422 | `blocked` | Gemini declined to answer |
| 429 | `rate_limited`, `daily_limit_reached`, `quota_or_rate_limit` | Backend limit, or Gemini rate limit / free quota |
| 502 | `upstream_unreachable`, `upstream_auth`, `model_not_found`, `invalid_upstream_response`, `empty_response`, `upstream_bad_request`, `upstream_error` | Problem talking to Gemini |
| 503 | `server_not_configured`, `upstream_unavailable` | Missing env vars / Gemini down |
| 504 | `upstream_timeout` | Gemini took longer than `UPSTREAM_TIMEOUT_MS` |

Error messages never contain your API key, access token or message text, and request bodies are never logged.

## Environment variables
See `env.example` for every name. The important ones:

| Name | Required | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | yes | Your Google AI Studio key |
| `APP_ACCESS_TOKEN` | yes | A long random string you invent. The app sends it; strangers cannot use your quota |
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
