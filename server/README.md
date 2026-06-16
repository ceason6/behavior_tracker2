# Web AI proxy

The "Generate Description" and "AI behavior analysis" features call the Anthropic
(Claude) API. Browsers block that call directly (CORS), so the web build routes
AI requests through this small proxy, which also serves the compiled web app.

Everything else in the app (logging, history, charts, PDF report/print) works
in the browser without the proxy.

## Run it

```bash
flutter build web
dart run server/proxy.dart
# open http://localhost:8787
```

Because the app and the proxy are served from the same origin, the web build
calls `/v1/messages` and the proxy forwards it to Anthropic — no CORS, and the
API key never reaches the browser.

## Where the API key comes from

The proxy always uses the **server-side** `ANTHROPIC_API_KEY` from its
environment, so the key stays on the server and the browser never holds it. A
client-supplied `x-api-key` is honored only as a fallback when no server key is
configured (e.g. plain local dev) — a stale browser-cached key can never override
the server key.

```bash
ANTHROPIC_API_KEY=sk-ant-... dart run server/proxy.dart
```

## Staff password gate

Set `APP_PASSWORD` to require a login on the whole app (and the proxy). The
browser shows a Basic-auth prompt; enter any username and the password. The
`/healthz` probe stays open. Leave it unset only for local testing — the proxy
logs a warning when the app is open.

```bash
ANTHROPIC_API_KEY=sk-ant-... APP_PASSWORD=choose-a-password dart run server/proxy.dart
```

## Rotating keys (server/rotate-key.sh)

Anthropic's Admin API **cannot create** keys (Console-only), so create the new key
in the Console first, then:

1. Create a new key in the Console (in the workspace that holds your credits).
2. Paste it into the proxy's `ANTHROPIC_API_KEY` (on Render: Environment →
   Environment Variables → save → it redeploys).
3. Disable the old key:

```bash
export ANTHROPIC_ADMIN_KEY=sk-ant-admin-...     # org accounts only

./server/rotate-key.sh list                      # find the OLD key's id (apikey_...)
./server/rotate-key.sh disable apikey_OLDID      # deactivate it
```

The `list`/`disable` commands require an **Admin API key** (`sk-ant-admin...`)
and an **organization** account (the Admin API is unavailable on individual
accounts).

## Environment variables

| Variable            | Default     | Purpose                                                              |
| ------------------- | ----------- | ------------------------------------------------------------------- |
| `PORT`              | `8787`      | Port to listen on (Render injects this)                             |
| `WEB_DIR`           | `build/web` | Directory of the built Flutter web app                             |
| `ANTHROPIC_API_KEY` | _(unset)_   | Server-side Anthropic key the proxy always uses for AI requests     |
| `APP_PASSWORD`      | _(unset)_   | Staff login password; when set, Basic auth is required (app is open if unset) |

## Using a separately-hosted proxy

If you serve the web app somewhere other than this proxy, build it with the
proxy's URL so AI calls are sent there (the proxy already returns CORS headers):

```bash
flutter build web --dart-define=ANTHROPIC_PROXY=https://your-proxy.example.com
```

## Get an API key

Create a key at https://console.anthropic.com → API keys. Anthropic keys start
with `sk-ant-`. Usage is billed per token; the analysis uses `claude-opus-4-8`.
