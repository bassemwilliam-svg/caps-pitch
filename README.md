# MCC — Capability Intelligence Platform · Phase 2 Pitch

Bilingual (English · Arabic) pitch site for the Monitoring &amp; Control Center
(MCC) Phase 2 proposal. Hosted statically on GitHub Pages.

## Live demo

Served at the GitHub Pages URL for this repo.

## AI assistant

The "CAPS AI Assistant" section calls a server-side Cloudflare Worker proxy
that holds the Anthropic API key. The Worker source lives in [`/worker`](worker).
Deploy it with:

```bash
cd worker
./deploy.sh
```

Until the Worker is deployed and its URL is pasted into `PROD_CLAUDE_PROXY_URL`
at the top of `index.html`, the assistant runs in scripted-fallback mode
(status pill shows "GROUNDED"); the answers are still grounded in the same
source data — they just don't reason live.

## Local preview

```bash
# Static server for the pitch site
python3 -m http.server 8082

# In a second terminal, for the live-AI path:
cd worker && npx wrangler dev
```

Open <http://localhost:8082>.

## Structure

```
index.html            — the pitch site (single file, English + Arabic)
mcc-logo.svg          — official MCC wordmark (as served by mcc.gov.ae)
visuals/              — scenario imagery, diagrams, UI mockups
worker/               — Cloudflare Worker proxy (server-side key, CORS-limited)
```

## Access

The pitch site is gated by a session password (set in `index.html`
as a SHA-256 hash).
