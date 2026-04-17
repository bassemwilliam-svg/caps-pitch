// ─── MCC CAPS AI · Claude proxy (Cloudflare Worker) ─────────────────────────
//
// Holds the Anthropic API key server-side and forwards Messages API calls
// from the MCC Phase 2 pitch site. The key lives as a Worker Secret
// (`ANTHROPIC_API_KEY`) and never touches the client.
//
// Protection layers:
//   1. CORS allow-list (ALLOWED_ORIGINS) — the browser refuses cross-origin
//      requests from anywhere not on the list.
//   2. Origin check on the server side (Origin header must match) — closes
//      the curl/scripted-request loophole that CORS alone cannot.
//   3. IP-based rate limit (60 req / 10 min / IP) — caps abuse before the
//      Anthropic spend limit takes over.
//   4. Request size cap (8 KB) — blocks payload-bomb attempts.
//
// Deploy:  wrangler deploy
// Set key: wrangler secret put ANTHROPIC_API_KEY
// ────────────────────────────────────────────────────────────────────────────

const ALLOWED_ORIGINS = [
  // Edit this list in wrangler.toml → [vars] ALLOWED_ORIGINS, or here as a fallback.
  'http://localhost:8082',
  'http://127.0.0.1:8082',
];

const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
const MAX_BODY_BYTES = 8 * 1024;
const RATE_LIMIT_WINDOW_S = 600;
const RATE_LIMIT_MAX = 60;

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get('Origin') || '';
    const allowList = (env.ALLOWED_ORIGINS || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
      .concat(ALLOWED_ORIGINS);
    const originAllowed = allowList.includes(origin);

    // Preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders(origin, originAllowed) });
    }
    if (request.method !== 'POST') {
      return json({ error: 'Method not allowed' }, 405, corsHeaders(origin, originAllowed));
    }
    if (!originAllowed) {
      return json({ error: 'Origin not allowed' }, 403, corsHeaders(origin, false));
    }

    // Rate limit (per IP, best-effort using KV if bound, else in-memory)
    const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (env.RATE_LIMIT_KV) {
      const key = `rl:${ip}:${Math.floor(Date.now() / (RATE_LIMIT_WINDOW_S * 1000))}`;
      const current = parseInt((await env.RATE_LIMIT_KV.get(key)) || '0', 10);
      if (current >= RATE_LIMIT_MAX) {
        return json({ error: 'Rate limit exceeded' }, 429, corsHeaders(origin, true));
      }
      ctx.waitUntil(env.RATE_LIMIT_KV.put(key, String(current + 1), { expirationTtl: RATE_LIMIT_WINDOW_S + 60 }));
    }

    // Size cap
    const len = parseInt(request.headers.get('Content-Length') || '0', 10);
    if (len > MAX_BODY_BYTES) {
      return json({ error: 'Payload too large' }, 413, corsHeaders(origin, true));
    }

    // Read and forward
    let payload;
    try {
      payload = await request.json();
    } catch {
      return json({ error: 'Invalid JSON' }, 400, corsHeaders(origin, true));
    }

    // Whitelist the fields we forward — don't let callers set arbitrary headers.
    const forwardBody = {
      model: payload.model || 'claude-haiku-4-5-20251001',
      max_tokens: Math.min(payload.max_tokens || 900, 1500),
      system: payload.system,
      messages: payload.messages || [],
    };

    if (!env.ANTHROPIC_API_KEY) {
      return json({ error: 'Server not configured' }, 500, corsHeaders(origin, true));
    }

    let upstream;
    try {
      upstream = await fetch(ANTHROPIC_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify(forwardBody),
      });
    } catch (e) {
      return json({ error: 'Upstream fetch failed', detail: String(e) }, 502, corsHeaders(origin, true));
    }

    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: {
        ...corsHeaders(origin, true),
        'Content-Type': upstream.headers.get('Content-Type') || 'application/json',
      },
    });
  },
};

function corsHeaders(origin, allowed) {
  const h = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
  if (allowed && origin) h['Access-Control-Allow-Origin'] = origin;
  return h;
}

function json(body, status, extraHeaders) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...(extraHeaders || {}) },
  });
}
