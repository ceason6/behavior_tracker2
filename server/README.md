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
API key never has to be hard-coded into the site.

## Where the API key comes from

- **Per-user (default):** each user enters their own key via the 🔑 / ⚙ settings;
  the app sends it as `x-api-key` and the proxy forwards it.
- **Server-side (optional):** set `ANTHROPIC_API_KEY` in the proxy's environment.
  The proxy then uses it for any request that arrives without an `x-api-key`
  header, so the key stays on the server and never reaches the browser.

```bash
ANTHROPIC_API_KEY=sk-ant-... dart run server/proxy.dart
```

## Environment variables

| Variable            | Default     | Purpose                                   |
| ------------------- | ----------- | ----------------------------------------- |
| `PORT`              | `8787`      | Port to listen on                         |
| `WEB_DIR`           | `build/web` | Directory of the built Flutter web app    |
| `ANTHROPIC_API_KEY` | _(unset)_   | Optional server-side fallback key         |

## Using a separately-hosted proxy

If you serve the web app somewhere other than this proxy, build it with the
proxy's URL so AI calls are sent there (the proxy already returns CORS headers):

```bash
flutter build web --dart-define=ANTHROPIC_PROXY=https://your-proxy.example.com
```

## Get an API key

Create a key at https://console.anthropic.com → API keys. Anthropic keys start
with `sk-ant-`. Usage is billed per token; the analysis uses `claude-opus-4-8`.
