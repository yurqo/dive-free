/**
 * DiveFree Strava token proxy.
 *
 * Holds the Strava `client_secret` server-side so it never ships in the app
 * binary. The app runs the browser auth-code step itself (no secret needed),
 * then POSTs the resulting `code` / `refresh_token` here. This Worker adds
 * `client_id` + `client_secret` and forwards to Strava's token endpoint,
 * returning Strava's JSON response and status code verbatim.
 *
 * Endpoints (routed by host):
 *   strava.* host — the token proxy:
 *     POST /token    { code }          -> Strava grant_type=authorization_code
 *     POST /refresh  { refresh_token } -> Strava grant_type=refresh_token
 *   public site host (divefree.software-engineer.ing):
 *     GET  /privacy                    -> HTML privacy policy (App Store listing)
 *     GET  /support                    -> HTML support page (App Store listing)
 */

export interface Env {
  // Set via `wrangler secret put` (persist across deploys; not in wrangler.toml).
  STRAVA_CLIENT_ID: string;
  STRAVA_CLIENT_SECRET: string;
  // Optional override (declared in wrangler.toml [vars]); defaults below.
  STRAVA_TOKEN_URL?: string;
}

const DEFAULT_TOKEN_URL = "https://www.strava.com/oauth/token";

// Public site host (apex). Serves only GET /privacy; the Strava proxy endpoints
// (/token, /refresh) answer on the strava.* host, never here.
const PUBLIC_SITE_HOST = "divefree.software-engineer.ing";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Forwards a form-encoded grant to Strava, passing back its body + status. */
async function exchange(env: Env, fields: Record<string, string>): Promise<Response> {
  const body = new URLSearchParams({
    client_id: env.STRAVA_CLIENT_ID,
    client_secret: env.STRAVA_CLIENT_SECRET,
    ...fields,
  });

  const upstream = await fetch(env.STRAVA_TOKEN_URL ?? DEFAULT_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  // Pass Strava's JSON + status straight through; the app decodes the fields
  // it needs (access_token / refresh_token / expires_at) and ignores the rest.
  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { "Content-Type": "application/json" },
  });
}

/**
 * Privacy policy page served at GET /privacy for the App Store listing.
 * Canonical, human-readable copy lives in docs/privacy-policy.md — keep the two
 * in sync (this is a deliberate copy to avoid a markdown-renderer dependency in
 * the Worker; the policy is a stable document).
 */
const PRIVACY_POLICY_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DiveFree Privacy Policy</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         line-height: 1.6; max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.25rem; }
  h1 { font-size: 1.7rem; margin-bottom: 0.25rem; }
  h2 { font-size: 1.2rem; margin-top: 2rem; }
  h3 { font-size: 1.05rem; margin-top: 1.5rem; }
  .effective { color: #6b7280; margin-top: 0; }
  a { color: #0a84ff; }
</style>
</head>
<body>
<h1>DiveFree Privacy Policy</h1>
<p class="effective">Effective date: June 25, 2026</p>

<p>DiveFree (&ldquo;the app,&rdquo; &ldquo;we,&rdquo; &ldquo;us&rdquo;) is a freediving and snorkeling session logger for Apple Watch and iPhone. The app is designed to keep your data on your own devices and under your control. This policy explains what data the app handles and where it goes.</p>

<h2>Summary</h2>
<ul>
<li><strong>Your dive data stays on your devices.</strong> We do not operate a server that stores your personal data, and we have no access to your dives, health data, location, photos, or voice notes.</li>
<li><strong>No analytics, advertising, or third-party tracking SDKs.</strong> The app does not track you across apps or websites.</li>
<li>Data leaves your device only when <strong>you</strong> choose to share it (for example, exporting a dive to Strava) or through Apple&rsquo;s own system services.</li>
</ul>

<h2>What the app handles</h2>

<h3>Health &amp; fitness</h3>
<p>With your permission, the app reads and writes workout data through Apple HealthKit to record your dive sessions as workouts. This data is stored by Apple Health on your device; we never receive it and never use it for advertising or marketing. It is not shared with third parties &mdash; except that, if you choose to export a session to Strava, the exported activity can include your heart rate (see Strava below).</p>

<h3>Location</h3>
<p>With your permission, the app records where your dives happen so it can group them into dive spots and show them on a map. Coordinates are stored on your device. To turn coordinates into place names, the app uses Apple&rsquo;s geocoding service, which sends coordinates to Apple under Apple&rsquo;s privacy policy. Location is never used to track you.</p>

<h3>Photos &amp; videos</h3>
<p>With your permission, the app references photos and videos from your photo library to attach them to dive spots and sessions, and can organize them into a &ldquo;Dive Free&rdquo; album. The app references your existing library items &mdash; it does not upload them anywhere, and they remain in your photo library.</p>

<h3>Voice notes</h3>
<p>Voice notes you record are stored as audio files on your device.</p>

<h3>Strava (optional)</h3>
<p>If you connect Strava, the app exports the dives you choose as Strava activities. Sign-in uses Strava&rsquo;s OAuth; it is brokered by a stateless relay we operate <strong>solely</strong> to keep Strava&rsquo;s client secret off your device &mdash; the relay stores no user data or tokens. Your Strava access tokens are stored on your device. Activity data you export (such as the time, duration, depth, location, and heart rate of the dive) is sent to Strava and is then governed by <a href="https://www.strava.com/legal/privacy">Strava&rsquo;s privacy policy</a>.</p>

<h2>What we do NOT do</h2>
<p>We do not collect, transmit to ourselves, or sell your personal data. The app contains no analytics, advertising, crash-tracking SDKs, or device fingerprinting.</p>

<h2>Retention &amp; deletion</h2>
<p>Because your data lives on your device, you control it. Deleting a session, photo reference, or the app removes the associated data from the app. Health data is managed in Apple Health, photos in the Photos app, and exported activities in Strava.</p>

<h2>Children</h2>
<p>The app is not directed at children under 13 and does not knowingly collect data from them.</p>

<h2>Changes</h2>
<p>We may update this policy; material changes will be reflected by the effective date above.</p>

<h2>Contact</h2>
<p>Questions about this policy: <a href="mailto:dive-free@software-engineer.ing">dive-free@software-engineer.ing</a></p>
</body>
</html>`;

// Support page served at GET /support for the App Store listing. Mirrors the
// privacy page's shell — keep the <style> in sync if it ever changes.
const SUPPORT_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DiveFree Support</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         line-height: 1.6; max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.25rem; }
  h1 { font-size: 1.7rem; margin-bottom: 0.25rem; }
  h2 { font-size: 1.2rem; margin-top: 2rem; }
  a { color: #0a84ff; }
</style>
</head>
<body>
<h1>DiveFree Support</h1>
<p>DiveFree is a logbook for recreational freediving and snorkeling on Apple Watch and iPhone. It is not a dive computer or a safety device.</p>

<h2>Get help</h2>
<p>Questions, bug reports, and feature requests are welcome &mdash; email <a href="mailto:dive-free@software-engineer.ing">dive-free@software-engineer.ing</a> and we&rsquo;ll get back to you.</p>

<h2>Good to know</h2>
<ul>
<li>Depth tracking requires an Apple Watch Ultra, Series 10, or Series 11. Other Apple Watch models log sessions with GPS location and heart rate.</li>
<li>On Apple Watch Ultra you can start and stop dives and drop markers underwater, hands-free, using the watch&rsquo;s buttons.</li>
<li>Strava export is optional &mdash; connect it in Settings, then share the dives you choose.</li>
</ul>

<h2>Privacy</h2>
<p>Read our <a href="/privacy">Privacy Policy</a>.</p>
</body>
</html>`;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname, hostname } = new URL(request.url);

    // The public site host serves ONLY the privacy policy; the Strava token
    // proxy lives on the strava.* host. Routing by host keeps the token proxy
    // off the public domain and the policy off the proxy domain.
    if (hostname === PUBLIC_SITE_HOST) {
      const page =
        pathname === "/privacy" ? PRIVACY_POLICY_HTML :
        pathname === "/support" ? SUPPORT_HTML :
        null;
      if (page === null) {
        return json({ error: "not_found" }, 404);
      }
      if (request.method !== "GET" && request.method !== "HEAD") {
        return json({ error: "method_not_allowed" }, 405);
      }
      return new Response(page, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "public, max-age=3600",
        },
      });
    }

    // Strava token proxy (strava.* host): /privacy is not served here.
    if (pathname !== "/token" && pathname !== "/refresh") {
      return json({ error: "not_found" }, 404);
    }
    if (request.method !== "POST") {
      return json({ error: "method_not_allowed" }, 405);
    }

    let payload: Record<string, unknown>;
    try {
      payload = (await request.json()) as Record<string, unknown>;
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    if (pathname === "/token") {
      const code = payload.code;
      if (typeof code !== "string" || code === "") {
        return json({ error: "missing_code" }, 400);
      }
      return exchange(env, { code, grant_type: "authorization_code" });
    }

    // pathname === "/refresh"
    const refreshToken = payload.refresh_token;
    if (typeof refreshToken !== "string" || refreshToken === "") {
      return json({ error: "missing_refresh_token" }, 400);
    }
    return exchange(env, { refresh_token: refreshToken, grant_type: "refresh_token" });
  },
} satisfies ExportedHandler<Env>;
