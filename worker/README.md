# MCC CAPS AI — Claude Proxy (Cloudflare Worker)

Holds the Anthropic API key server-side so the public pitch site can call
Claude without exposing credentials in the browser. CORS-restricted to your
production origin, IP rate-limited, payload-size capped.

## One-time deploy

1. **Install Wrangler** (Cloudflare's CLI) and log in:
   ```bash
   npm install
   npx wrangler login
   ```
2. **Set the Anthropic key as a secret** (never commit it):
   ```bash
   npx wrangler secret put ANTHROPIC_API_KEY
   # paste the key when prompted
   ```
3. **Edit `wrangler.toml`** — replace `https://your-site.com` in
   `ALLOWED_ORIGINS` with the domain you're deploying the pitch site to.
   Use a comma-separated list for multiple origins.
4. **(Optional) Rate limiting**: create a KV namespace and uncomment the
   `[[kv_namespaces]]` block in `wrangler.toml`:
   ```bash
   npx wrangler kv:namespace create RATE_LIMIT_KV
   # paste the returned id into wrangler.toml
   ```
5. **Deploy**:
   ```bash
   npm run deploy
   ```
   Wrangler prints your Worker URL, e.g.
   `https://mcc-caps-ai.<your-subdomain>.workers.dev`.

## Wire the pitch site to the Worker

In `index-mcc.html`, find `CLAUDE_PROXY_URL` and replace its value with the
deployed Worker URL (no trailing slash). That's the only client-side change.

## Key rotation

When you need to rotate the Anthropic key:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
```

Paste the new key. Takes effect immediately on the next request — no redeploy
needed.

## Local development

```bash
npm run dev
```

Runs the Worker at `http://127.0.0.1:8787`. Point `CLAUDE_PROXY_URL` at it to
test end-to-end locally.

## Verifying access control

```bash
# Should succeed (your origin is allowed):
curl -X POST -H "Origin: https://your-site.com" \
     -H "Content-Type: application/json" \
     -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"hi"}]}' \
     https://mcc-caps-ai.<your-subdomain>.workers.dev

# Should return 403 (origin not allowed):
curl -X POST -H "Origin: https://evil.example" \
     -d '{}' \
     https://mcc-caps-ai.<your-subdomain>.workers.dev
```

## Monitoring

```bash
npm run tail     # live log stream from the Worker
```

Set a spend limit on the Anthropic account (`console.anthropic.com` → Limits)
as a last line of defence.
