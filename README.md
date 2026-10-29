<div align="center">
<img width="1200" height="475" alt="GHBanner" src="https://github.com/user-attachments/assets/0aa67016-6eaf-458a-adb2-6e31a0763ed6" />
</div>

# Aid'Habitat Manager

## Run locally

**Prerequisites:** Node.js

1. Install dependencies: `npm install`
2. Run the app: `npm run dev`

## Note rewriting with OpenRouter

Written notes use `deepseek/deepseek-v4-flash` through the authenticated API.
Set `OPENROUTER_API_KEY` on the server. No key or local language model is
shipped to the browser or iPad. Rewriting is independent of the visit assistant
feature flag and its transcription/vision model settings.

Authenticated endpoints:

- `GET /api/ai/status`
- `POST /api/ai/rewrite` with `{ "text": "...", "mode": "professional" }`

Modes: `professional`, `concise`, `correct`. The editable proposal is reviewed
before replacing the source. Requests use price routing, reasoning disabled,
and the existing ZDR/no-data-collection provider constraints. Truncated output
or changes to protected facts are rejected. Rewriting requires connectivity;
o local fallback is used. Existing browser rewrite model caches are retired
at the next page load without touching the local patient database.
