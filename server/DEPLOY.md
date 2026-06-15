# Deploying the ABC Behavior Tracker

This deploys one Docker web service (the Dart proxy) that **serves the Flutter
web app and forwards AI calls to Anthropic**, fronted by **Cloudflare** for
HTTPS, a WAF, and staff-only access (SSO). All student data stays in each
browser — there is no database to run.

> ⚠️ **Before going live with real student data:** the AI features send ABC
> data to Anthropic. Confirm FERPA / district policy, and consider a
> data-processing agreement and/or zero-data-retention with Anthropic, or gate
> the AI features for sensitive records.

---

## 1. Deploy to Render

1. Push this repo to GitHub (already done).
2. In Render: **New → Blueprint**, select the repo. Render reads `render.yaml`
   and creates the `abc-behavior-tracker` Docker web service.
   - (Or **New → Web Service → Docker** and point it at this repo if you prefer
     not to use the blueprint.)
3. Add the API key — **Service → Environment → Secret Files → Add Secret File**:
   - **Filename:** `anthropic.key`
   - **Contents:** your `sk-ant-...` key (no quotes, no trailing newline)
   - It mounts at `/etc/secrets/anthropic.key`, which `ANTHROPIC_API_KEY_FILE`
     already points to. (Prefer this over an env var so the key lives in a file.)
4. Deploy. You get a URL like `https://abc-behavior-tracker.onrender.com`.
   Open it — the web app loads and the AI features use the server-side key (users
   don't enter their own).

**Notes**
- The free plan cold-starts after idle; upgrade to `starter` for always-on.
- `PORT` is injected by Render; the proxy honors it automatically.
- To rotate the key: update the Secret File (Render redeploys), or create a new
  key in the Anthropic Console and disable the old one with
  `server/rotate-key.sh disable <api_key_id>` (needs an Admin key + org account).

## 2. Put Cloudflare in front (HTTPS + WAF + staff-only SSO)

Requires a domain you manage on Cloudflare (e.g. `tracker.yourschool.org`).

1. **Render:** Service → Settings → **Custom Domain** → add `tracker.yourschool.org`;
   Render shows a target hostname.
2. **Cloudflare DNS:** add a **CNAME** `tracker` → that Render hostname, **Proxied**
   (orange cloud). TLS is automatic.
3. **WAF:** Security → WAF → enable the managed ruleset (on by default for proxied
   hostnames).
4. **Staff-only access (Cloudflare Access / Zero Trust):**
   - Zero Trust → Access → **Applications → Add → Self-hosted**.
   - Application domain: `tracker.yourschool.org`.
   - Add a **policy**: Allow → e.g. *Emails ending in* `@yourschool.org`, or a
     Google Workspace / Okta identity provider, or a specific email list.
   - Now only authenticated staff can reach the app; everyone else is blocked at
     the edge, before the request ever hits the proxy or the API key.

After this, the only public surface is Cloudflare, the app is HTTPS-only and
staff-gated, and the Anthropic key never leaves the server.

## 3. Alternatives (same shape)

- **Fly.io:** `fly launch` (uses the Dockerfile), `fly secrets set` for the key,
  then the same Cloudflare steps. Tiny always-on VMs.
- **Google Cloud Run:** deploy the Dockerfile, mount the key from **Secret
  Manager as a file** at `/etc/secrets/anthropic.key` (matches
  `ANTHROPIC_API_KEY_FILE`), and gate with **IAP** or Cloudflare.

## 4. Local run (no Docker)

```bash
flutter build web
ANTHROPIC_API_KEY_FILE=secrets/anthropic.key dart run server/proxy.dart
# http://localhost:8787
```
