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
| `GET /privacy` | —                    | HTML privacy policy for the App Store listing          |

Both return Strava's JSON (`access_token`, `refresh_token`, `expires_at`, …) and
status code verbatim.

## Configuration

- **`name`** in `wrangler.toml` is `dive-free`.
- **Custom domains:** two `[[routes]]` entries (bare hostnames — `custom_domain`
  routes take no path/`/*`): `strava.divefree.software-engineer.ing` (must match
  `StravaConfig.proxyBaseURL` in the app) and `divefree.software-engineer.ing`
  (public privacy-policy page at `/privacy`). The zone must be on this Cloudflare
  account.
- **Secrets** (set once; they persist across deploys and are *not* needed at
  build time):

  ```sh
  cd Server
  npm install
  npx wrangler secret put STRAVA_CLIENT_ID
  npx wrangler secret put STRAVA_CLIENT_SECRET
  ```

## Deploy

Deployment is handled by **Cloudflare Workers Builds** (git integration): the
`yurqo/dive-free` repo is connected with **Root directory = `Server`**,
production branch `main` → `npx wrangler deploy` (non-production branches use
`npx wrangler versions upload` for previews). Pushes that touch `Server/**`
auto-deploy.

For a one-off manual deploy: `cd Server && npm run deploy`.

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
