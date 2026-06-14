# Web AI proxy

The "Generate Description" and "AI behavior analysis" features call the OpenAI
API. Browsers block that call directly (CORS), so the web build routes AI
requests through this small proxy, which also serves the compiled web app.

Everything else in the app (logging, history, charts, PDF report/print) works
in the browser without the proxy.

## Run it

```bash
flutter build web
dart run server/proxy.dart
# open http://localhost:8787
```

Because the app and the proxy are served from the same origin, the web build
calls `/v1/chat/completions` and the proxy forwards it to OpenAI — no CORS, and
the OpenAI API key never has to be hard-coded into the site.

## Where the API key comes from

- **Per-user (default):** each user enters their own key via the ⚙ settings on
  the home screen; the app sends it and the proxy forwards it.
- **Server-side (optional):** set `OPENAI_API_KEY` in the proxy's environment.
  The proxy then uses it for any request that arrives without an `Authorization`
  header, so the key stays on the server and never reaches the browser.

```bash
OPENAI_API_KEY=sk-... dart run server/proxy.dart
```

## Environment variables

| Variable         | Default     | Purpose                                  |
| ---------------- | ----------- | ---------------------------------------- |
| `PORT`           | `8787`      | Port to listen on                        |
| `WEB_DIR`        | `build/web` | Directory of the built Flutter web app   |
| `OPENAI_API_KEY` | _(unset)_   | Optional server-side fallback key        |

## Using a separately-hosted proxy

If you serve the web app somewhere other than this proxy, build it with the
proxy's URL so AI calls are sent there (the proxy already returns CORS headers):

```bash
flutter build web --dart-define=OPENAI_PROXY=https://your-proxy.example.com
```
