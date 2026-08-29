// send-push - invoked by a Supabase Database Webhook on INSERT into "NotifLog".
// Signs an APNs JWT with the .p8 auth key and delivers to every registered device.

import { SignJWT, importPKCS8 } from "npm:jose@5";

const KEY_ID = Deno.env.get("APNS_KEY_ID")!;
const TEAM_ID = Deno.env.get("APNS_TEAM_ID")!;
const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID")!;
const P8 = Deno.env.get("APNS_P8")!;
const ENVIRONMENT = Deno.env.get("APNS_ENVIRONMENT") ?? "development";
const WEBHOOK_SECRET = Deno.env.get("WEBHOOK_SECRET")!;

// Auto-injected into every Edge Function by Supabase.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const APNS_HOST = ENVIRONMENT === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

// APNs accepts a token for 1h and rejects regeneration more than once per 20min,
// so cache it in module scope for the lifetime of the isolate.
let cachedToken: { jwt: string; issuedAt: number } | null = null;

async function apnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 45 * 60) {
    return cachedToken.jwt;
  }
  const key = await importPKCS8(P8, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: KEY_ID })
    .setIssuer(TEAM_ID)
    .setIssuedAt(now)
    .sign(key);

  cachedToken = { jwt, issuedAt: now };
  return jwt;
}

async function deviceTokens(): Promise<string[]> {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/devices?select=device_token&environment=eq.${ENVIRONMENT}`,
    {
      headers: {
        apikey: SERVICE_ROLE,
        Authorization: `Bearer ${SERVICE_ROLE}`,
      },
    },
  );
  if (!res.ok) {
    throw new Error(`Could not read devices: ${res.status} ${await res.text()}`);
  }
  const rows = await res.json() as Array<{ device_token: string }>;
  return rows.map((r) => r.device_token);
}

async function sendTo(token: string, jwt: string, body: string) {
  const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: {
        alert: { title: "Apns-Scheduler", body },
        sound: "default",
      },
    }),
  });

  // 410 Gone / BadDeviceToken means the token is dead - prune it so the
  // devices table doesn't accumulate addresses that can never be delivered to.
  if (res.status === 410 || res.status === 400) {
    const detail = await res.text();
    if (detail.includes("BadDeviceToken") || detail.includes("Unregistered")) {
      await fetch(
        `${SUPABASE_URL}/rest/v1/devices?device_token=eq.${token}`,
        {
          method: "DELETE",
          headers: {
            apikey: SERVICE_ROLE,
            Authorization: `Bearer ${SERVICE_ROLE}`,
          },
        },
      );
    }
    return { token, status: res.status, detail, pruned: true };
  }

  return {
    token,
    status: res.status,
    detail: res.ok ? "ok" : await res.text(),
    pruned: false,
  };
}

Deno.serve(async (req) => {
  // The function URL is public, so the shared secret is what stops anyone
  // who finds it from firing arbitrary pushes at your users.
  if (req.headers.get("x-webhook-secret") !== WEBHOOK_SECRET) {
    return new Response("unauthorized", { status: 401 });
  }

  try {
    const payload = await req.json();
    const text: string | undefined = payload?.record?.text;
    if (!text) {
      return new Response(
        JSON.stringify({ error: "no record.text in webhook payload" }),
        { status: 400, headers: { "content-type": "application/json" } },
      );
    }

    const tokens = await deviceTokens();
    if (tokens.length === 0) {
      return new Response(
        JSON.stringify({ sent: 0, note: "no devices registered" }),
        { headers: { "content-type": "application/json" } },
      );
    }

    const jwt = await apnsToken();
    const results = await Promise.all(tokens.map((t) => sendTo(t, jwt, text)));

    return new Response(
      JSON.stringify({
        sent: results.filter((r) => r.status === 200).length,
        results,
      }),
      { headers: { "content-type": "application/json" } },
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }
});
