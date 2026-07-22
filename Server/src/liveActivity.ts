/**
 * Live Activity push-to-start (#18, stage 2).
 *
 * The iPhone app, when a watch session starts while the app is backgrounded and
 * ActivityKit can't start a Live Activity locally, POSTs here with its current
 * push-to-start token. This Worker sends an APNs `event: "start"` push so iOS
 * starts the Live Activity (auto Dynamic Island) with no foreground needed.
 *
 * STATELESS by design: no D1/KV, no registration endpoint. The phone carries its
 * live token (which rotates) in every request, so there is nothing to persist and
 * nothing to go stale. The Worker just signs a JWT and relays one push.
 *
 * Secrets (set via `wrangler secret put`, never committed — this repo is public):
 *   APNS_AUTH_KEY  — the APNs auth key .p8. PIPE the file, don't paste it:
 *                    `wrangler secret put APNS_AUTH_KEY < AuthKey_XXXXXXXXXX.p8`.
 *                    The interactive prompt reads a single line, so a pasted
 *                    multiline PEM stores only the BEGIN header (→ bad_key_material).
 *   APNS_KEY_ID    — the 10-char Key ID of that .p8 (one-liner)
 *   APPLE_TEAM_ID  — the 10-char Apple Developer Team ID (JWT issuer, one-liner)
 */

export interface ApnsEnv {
  APNS_AUTH_KEY?: string;
  APNS_KEY_ID?: string;
  APPLE_TEAM_ID?: string;
}

// iOS bundle id (see Project.swift `bundlePrefix`). The Live Activity APNs topic
// is always "<bundle id>.push-type.liveactivity".
const IOS_BUNDLE_ID = "org.yurko.divefree";
const APNS_TOPIC = `${IOS_BUNDLE_ID}.push-type.liveactivity`;

// Must match the app's `Activity<DiveActivityAttributes>` / the widget's
// `ActivityConfiguration(for: DiveActivityAttributes.self)` type name so iOS can
// resolve which Live Activity to start.
const ATTRIBUTES_TYPE = "DiveActivityAttributes";

const APNS_HOST_PROD = "https://api.push.apple.com";
const APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com";

// --- Rate limiting -----------------------------------------------------------
// Best-effort, per-IP, in-memory sliding window. LIMITATION: state lives inside a
// single Worker isolate, so it is neither global nor durable — a burst spread
// across isolates/colos, or after an isolate recycles, is not fully bounded. This
// is acceptable at this scale (a personal app; the real cost cap is APNs itself);
// a Durable Object / KV counter would be the durable upgrade if abuse appears.
const RATE_LIMIT_MAX = 20; // requests
const RATE_LIMIT_WINDOW_MS = 60_000; // per minute, per IP
const rateHits = new Map<string, number[]>();

// A Live Activity APNs payload can't exceed 4096 bytes, so a well-formed request
// body is comfortably under this. Reject anything larger up front (FIX 7).
const MAX_BODY_BYTES = 4096;

function rateLimited(ip: string, now: number): boolean {
  const cutoff = now - RATE_LIMIT_WINDOW_MS;
  // Evict entries whose newest hit has aged out of the window so the Map can't
  // grow unbounded across many distinct IPs. Hits are appended in time order, so
  // the last element is the most recent. Deleting during Map iteration is safe.
  for (const [key, hits] of rateHits) {
    if (hits.length === 0 || hits[hits.length - 1] <= cutoff) rateHits.delete(key);
  }
  const recent = (rateHits.get(ip) ?? []).filter((t) => t > cutoff);
  recent.push(now);
  rateHits.set(ip, recent);
  return recent.length > RATE_LIMIT_MAX;
}

// --- APNs JWT (ES256) --------------------------------------------------------
// APNs accepts a provider JWT for 20–60 min; we cache ~40 min so we sign at most
// a couple of times an hour regardless of request volume (per isolate).
const JWT_TTL_MS = 40 * 60 * 1000;
let cachedJwt: { token: string; issuedAt: number } | null = null;
let cachedSigningKey: CryptoKey | null = null;

function base64UrlFromBytes(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const b of arr) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlFromString(s: string): string {
  return base64UrlFromBytes(new TextEncoder().encode(s));
}

/** Parses a PEM PKCS#8 private key body into DER bytes. */
function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return der.buffer;
}

/** Raised when APNS_AUTH_KEY isn't usable key material (see `signingKey`). */
class BadKeyMaterialError extends Error {}

async function signingKey(env: ApnsEnv): Promise<CryptoKey> {
  if (cachedSigningKey) return cachedSigningKey;
  // Defensive against the classic misconfiguration: `wrangler secret put` read
  // interactively captures only ONE line, so a pasted multiline PEM stores just
  // the "-----BEGIN PRIVATE KEY-----" header — the DER body is empty (or invalid)
  // and every request would fail while *looking* configured. Surface it as a
  // distinct BadKeyMaterialError → 503 bad_key_material so it's diagnosable from
  // the app-side status code. (Fix: pipe the .p8 file — see Server/README.md.)
  let der: ArrayBuffer;
  try {
    der = pemToDer(env.APNS_AUTH_KEY as string);
  } catch (e) {
    throw new BadKeyMaterialError(`PEM parse failed: ${String(e)}`);
  }
  if (der.byteLength === 0) throw new BadKeyMaterialError("empty key material");
  try {
    cachedSigningKey = await crypto.subtle.importKey(
      "pkcs8",
      der,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"]
    );
  } catch (e) {
    throw new BadKeyMaterialError(`importKey failed: ${String(e)}`);
  }
  return cachedSigningKey;
}

async function providerToken(env: ApnsEnv, now: number): Promise<string> {
  if (cachedJwt && now - cachedJwt.issuedAt < JWT_TTL_MS) return cachedJwt.token;
  const iat = Math.floor(now / 1000);
  const header = base64UrlFromString(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const payload = base64UrlFromString(JSON.stringify({ iss: env.APPLE_TEAM_ID, iat }));
  const signingInput = `${header}.${payload}`;
  // WebCrypto ECDSA P-256 sign returns the raw IEEE-P1363 r||s (64 bytes), which
  // is exactly the JWS/ES256 signature encoding APNs expects.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    await signingKey(env),
    new TextEncoder().encode(signingInput)
  );
  const token = `${signingInput}.${base64UrlFromBytes(sig)}`;
  cachedJwt = { token, issuedAt: now };
  return token;
}

// --- Push --------------------------------------------------------------------
interface StartBody {
  token: string;
  env: "sandbox" | "production";
  contentState: unknown;
}

function parseBody(raw: unknown): StartBody | null {
  if (typeof raw !== "object" || raw === null) return null;
  const b = raw as Record<string, unknown>;
  const token = b.token;
  const env = b.env;
  const contentState = b.contentState;
  // APNs device tokens are lowercase hex; keep the check loose but bounded
  // (8..200 hex chars) so a junk value can't blow past a sane upper limit.
  if (typeof token !== "string" || !/^[0-9a-fA-F]{8,200}$/.test(token)) return null;
  if (env !== "sandbox" && env !== "production") return null;
  if (typeof contentState !== "object" || contentState === null) return null;
  return { token, env, contentState };
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Sends one push-to-start to APNs at `host`, returning APNs' raw response. */
async function sendToApns(
  host: string,
  jwt: string,
  body: StartBody,
  nowSeconds: number
): Promise<Response> {
  const payload = {
    aps: {
      timestamp: nowSeconds,
      event: "start",
      "content-state": body.contentState,
      "attributes-type": ATTRIBUTES_TYPE,
      attributes: {},
      alert: {
        title: "Dive session",
        body: "Session running on your watch",
      },
    },
  };
  // APNs is HTTP/2-only; Cloudflare Workers' fetch negotiates HTTP/2 to the origin.
  return fetch(`${host}/3/device/${body.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "liveactivity",
      "apns-priority": "10",
      // Give APNs ~120 s to deliver, then drop it — a stale "session started" is
      // useless.
      "apns-expiration": String(nowSeconds + 120),
    },
    body: JSON.stringify(payload),
  });
}

/**
 * POST /live-activity/start — validate, rate-limit, sign, relay one APNs push.
 * Returns 202 on an accepted APNs relay (the app treats 2xx as "started, skip the
 * local-notification fallback"); non-2xx tells the app to fall back.
 */
export async function handleLiveActivityStart(request: Request, env: ApnsEnv): Promise<Response> {
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!env.APNS_AUTH_KEY || !env.APNS_KEY_ID || !env.APPLE_TEAM_ID) {
    return json({ error: "push_not_configured" }, 503);
  }

  const now = Date.now();
  const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
  if (rateLimited(ip, now)) return json({ error: "rate_limited" }, 429);

  // Body size cap (FIX 7): reject oversized bodies before parsing. Check the
  // advertised Content-Length first, then re-check the actual bytes read in case
  // the header is absent or lies.
  const declaredLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return json({ error: "payload_too_large" }, 400);
  }
  let raw: unknown;
  try {
    const text = await request.text();
    if (text.length > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 400);
    raw = JSON.parse(text);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const body = parseBody(raw);
  if (!body) return json({ error: "invalid_body" }, 400);

  const nowSeconds = Math.floor(now / 1000);
  let jwt: string;
  try {
    jwt = await providerToken(env, now);
  } catch (e) {
    // A misconfigured/empty APNS_AUTH_KEY gets its own diagnosable status; any
    // other signing failure stays a generic 500.
    if (e instanceof BadKeyMaterialError) return json({ error: "bad_key_material" }, 503);
    return json({ error: "jwt_signing_failed" }, 500);
  }

  const primaryHost = body.env === "production" ? APNS_HOST_PROD : APNS_HOST_SANDBOX;
  let apns = await sendToApns(primaryHost, jwt, body, nowSeconds);

  // A prod build whose token is actually a sandbox token (or vice-versa) gets
  // 400 BadDeviceToken; retry on the OTHER host once before giving up. Bidirectional
  // (prod→sandbox and sandbox→prod), single retry, no loop.
  if (apns.status === 400) {
    const text = await apns.clone().text();
    if (text.includes("BadDeviceToken")) {
      const otherHost = body.env === "production" ? APNS_HOST_SANDBOX : APNS_HOST_PROD;
      apns = await sendToApns(otherHost, jwt, body, nowSeconds);
    }
  }

  if (apns.ok) return json({ ok: true }, 202);
  const reason = await apns.text().catch(() => "");
  return json({ error: "apns_error", status: apns.status, reason }, 502);
}
