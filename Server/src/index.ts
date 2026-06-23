/**
 * DiveFree Strava token proxy.
 *
 * Holds the Strava `client_secret` server-side so it never ships in the app
 * binary. The app runs the browser auth-code step itself (no secret needed),
 * then POSTs the resulting `code` / `refresh_token` here. This Worker adds
 * `client_id` + `client_secret` and forwards to Strava's token endpoint,
 * returning Strava's JSON response and status code verbatim.
 *
 * Endpoints:
 *   POST /token    { code }          -> Strava grant_type=authorization_code
 *   POST /refresh  { refresh_token } -> Strava grant_type=refresh_token
 */

export interface Env {
  // Set via `wrangler secret put` (persist across deploys; not in wrangler.toml).
  STRAVA_CLIENT_ID: string;
  STRAVA_CLIENT_SECRET: string;
  // Optional override (declared in wrangler.toml [vars]); defaults below.
  STRAVA_TOKEN_URL?: string;
}

const DEFAULT_TOKEN_URL = "https://www.strava.com/oauth/token";

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);

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
