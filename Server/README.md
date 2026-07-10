# DiveFree Strava token proxy (Cloudflare Worker)

A tiny Worker that holds the Strava `client_secret` so it never ships inside the
app binary. Strava's OAuth has no PKCE / public-client flow, so the secret is
required for `code → token` exchange and refresh — this Worker performs both on
the app's behalf.

The app still runs the browser **authorization-code** step itself (no secret
needed there), then POSTs the result here.

## Endpoints

Routed by host: the Strava proxy answers on `strava.divefree.software-engineer.ing`;
the privacy policy and support page on the public apex `divefree.software-engineer.ing`.

| Host     | Method & path   | Behaviour                                            |
| -------- | --------------- | ---------------------------------------------------- |
| strava.* | `POST /token`   | `grant_type=authorization_code` exchange with Strava |
| strava.* | `POST /refresh` | `grant_type=refresh_token` refresh with Strava       |
| apex     | `GET /privacy`  | HTML privacy policy for the App Store listing        |
| apex     | `GET /support`  | HTML support page for the App Store listing          |
| apex     | `POST /live-activity/start` | APNs push-to-start a dive Live Activity (#18) |

`/token` and `/refresh` return Strava's JSON (`access_token`, `refresh_token`,
`expires_at`, …) and status code verbatim; `/privacy` returns HTML. A request to
the wrong host (e.g. `/privacy` on `strava.*`) gets a 404.

### `POST /live-activity/start` (Live Activity push-to-start, #18 stage 2)

The iPhone app calls this when a watch session starts while the app is
backgrounded and it can't start a Live Activity locally. **Stateless** — no
registration/DB; the phone sends its current push-to-start token in the request:

```jsonc
{
  "token": "<hex push-to-start token>",
  "env": "sandbox" | "production",   // which APNs host the token belongs to
  "contentState": { "snapshot": { /* LiveSessionSnapshot fields */ } }
}
```

The Worker signs an ES256 APNs JWT (`APNS_AUTH_KEY` / `APNS_KEY_ID` /
`APPLE_TEAM_ID`, cached ~40 min) and relays an `event: "start"` Live Activity
push to `api.push.apple.com` or `api.sandbox.push.apple.com` (falling back
prod→sandbox once on `BadDeviceToken`). Returns **202** when APNs accepts the
relay, **4xx/5xx** otherwise — the app treats non-2xx as its cue to fall back to
its local notification. Basic per-IP, in-memory rate limiting (best-effort,
per-isolate — see `src/liveActivity.ts`). Sending never blocks a foreground start;
it's purely the closed-app path.

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

### Live Activity push-to-start secrets (#18)

`POST /live-activity/start` needs an APNs auth key. Create a **Key** with the
**Apple Push Notifications service (APNs)** capability in the Apple Developer
portal (Certificates, Identifiers & Profiles ▸ Keys), download the `.p8`, and set:

```sh
cd Server
# PIPE the .p8 file — do NOT paste it. The interactive prompt reads a single
# line, so a multiline PEM would store only the "-----BEGIN PRIVATE KEY-----"
# header and every push fails (bad_key_material) while looking configured.
npx wrangler secret put APNS_AUTH_KEY < AuthKey_XXXXXXXXXX.p8   # the whole .p8 file
npx wrangler secret put APNS_KEY_ID     # the key's 10-char Key ID (one-liner)
npx wrangler secret put APPLE_TEAM_ID   # your 10-char Apple Developer Team ID (one-liner)
```

The `.p8` is a **secret** — never commit it (this repo is public). Without these
three set, the endpoint returns `503 push_not_configured` and the app silently
falls back to its local notification; a present-but-unusable `APNS_AUTH_KEY`
(e.g. only the header got stored) returns `503 bad_key_material` instead, so the
misconfiguration is distinguishable. Also required (app/portal side, not the
Worker): the iOS App ID must have **Push Notifications** enabled and the app must
ship the `aps-environment` entitlement (already in
`Apps/iPhoneApp/DiveFree.entitlements`) — regenerate provisioning after enabling.

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

`POST /live-activity/start` now enforces best-effort, per-IP, in-memory rate
limiting plus token/body-size caps (see `src/liveActivity.ts`). Stronger abuse
protection — a durable (KV / Durable Object) rate limiter and/or app attestation —
remains deferred (tracked in #99); the Strava proxy endpoints stay unthrottled.
