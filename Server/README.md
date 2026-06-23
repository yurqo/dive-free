# DiveFree Strava token proxy (Cloudflare Worker)

A tiny Worker that holds the Strava `client_secret` so it never ships inside the
app binary. Strava's OAuth has no PKCE / public-client flow, so the secret is
required for `code → token` exchange and refresh — this Worker performs both on
the app's behalf.

The app still runs the browser **authorization-code** step itself (no secret
needed there), then POSTs the result here.

## Endpoints

| Method & path  | Request body         | Behaviour                                              |
| -------------- | -------------------- | ------------------------------------------------------ |
| `POST /token`  | `{ "code": "..." }`  | `grant_type=authorization_code` exchange with Strava   |
| `POST /refresh`| `{ "refresh_token" }`| `grant_type=refresh_token` refresh with Strava         |

Both return Strava's JSON (`access_token`, `refresh_token`, `expires_at`, …) and
status code verbatim.

## Configuration

- **`name`** in `wrangler.toml` is `dive-free`.
- **Custom domain:** the `[[routes]]` `pattern` in `wrangler.toml` is set to
  `strava.divefree.software-engineer.ing` (a bare hostname — `custom_domain`
  routes take no path/`/*`). The zone must be on this Cloudflare account, and
  this host must match `StravaConfig.proxyBaseURL` in the app.
- **Secrets** (set once; they persist across deploys and are *not* needed at
  build time):

  ```sh
  cd Server
  npm install
  npx wrangler secret put STRAVA_CLIENT_ID
  npx wrangler secret put STRAVA_CLIENT_SECRET
  ```

## Deploy

Three deploy paths exist — **pick one as primary to avoid double deploys**:

1. **Cloudflare Workers Builds** (git integration): connect `yurqo/dive-free`,
   set **Root directory = `Server`**, deploy command `npx wrangler deploy`.
   Auto-deploys on push.
2. **GitHub Actions**: `.github/workflows/deploy-worker.yml` runs
   `wrangler deploy` on pushes touching `Server/**` (and on manual dispatch).
   Needs repo secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
3. **Manual**: `cd Server && npm run deploy`.

Recommended: keep Workers Builds for push-to-deploy and use the GitHub Actions
workflow as a manual (`workflow_dispatch`) fallback — or disable Workers Builds
auto-deploy if you'd rather GitHub Actions be the single source of truth.

## Local development

```sh
cd Server
npm install
# Provide secrets locally via .dev.vars (gitignored):
#   STRAVA_CLIENT_ID=...
#   STRAVA_CLIENT_SECRET=...
npm run dev
curl -X POST localhost:8787/refresh \
  -H 'Content-Type: application/json' \
  -d '{"refresh_token":"<a real refresh token>"}'
```

## Follow-up (not MVP)

Abuse protection — rate limiting and/or app attestation — is intentionally
deferred (tracked in #99).
