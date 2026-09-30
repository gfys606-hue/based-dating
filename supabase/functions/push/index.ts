// Sends push notifications through Firebase Cloud Messaging (HTTP v1).
// Called only by the database (send_push in migration 20260929000013_push.sql), never by the app.
//
// Deploy:  supabase functions deploy push --no-verify-jwt
// Secret:  FIREBASE_SERVICE_ACCOUNT = the whole service-account JSON file from
//          Firebase console → Project settings → Service accounts → Generate new private key
//
// Body: { "user_id": "...", "title": "...", "body": "...", "data": { "kind": "match", ... } }
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SA_RAW = Deno.env.get("FIREBASE_SERVICE_ACCOUNT") ?? "";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type ServiceAccount = { client_email: string; private_key: string; project_id: string };

// ---- Google OAuth token from the service account (cached ~50 min) ----
let cached: { token: string; exp: number } | null = null;

const b64url = (data: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function accessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp > now + 60) return cached.token;

  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const jwt = `${header}.${claims}.${b64url(sig)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  if (!res.ok) throw new Error(`Google auth failed: ${res.status} ${await res.text()}`);
  const t = await res.json();
  cached = { token: t.access_token, exp: now + (t.expires_in ?? 3600) };
  return cached.token;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Only our database knows this secret (generated in private.settings).
  const secret = req.headers.get("x-push-secret") ?? "";
  const { data: ok } = await admin.rpc("push_secret_ok", { p_secret: secret });
  if (ok !== true) return json({ error: "forbidden" }, 403);

  if (!SA_RAW) return json({ skipped: "FIREBASE_SERVICE_ACCOUNT not set" });
  const sa = JSON.parse(SA_RAW) as ServiceAccount;

  const { user_id, title, body, data } = await req.json().catch(() => ({}));
  if (!user_id) return json({ error: "missing user_id" }, 400);

  const { data: rows } = await admin.from("push_tokens").select("token").eq("user_id", user_id);
  if (!rows?.length) return json({ sent: 0 });

  const token = await accessToken(sa);
  const stringData: Record<string, string> = {};
  for (const [k, v] of Object.entries(data ?? {})) stringData[k] = String(v);

  let sent = 0;
  for (const { token: device } of rows) {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        message: {
          token: device,
          notification: { title: title ?? "Based", body: body ?? "" },
          data: stringData,
          android: {
            priority: "HIGH",
            notification: { channel_id: "based", color: "#4169E1", tag: stringData.match_id ?? stringData.kind },
          },
        },
      }),
    });
    if (res.ok) {
      sent++;
    } else {
      const err = await res.text();
      // Phone uninstalled the app or the token expired: forget it.
      if (res.status === 404 || err.includes("UNREGISTERED")) {
        await admin.from("push_tokens").delete().eq("token", device);
      } else {
        console.error("fcm", res.status, err);
      }
    }
  }
  return json({ sent });
});
