// Logs a site visit and pings the owner (admin accounts), with the visitor's city resolved
// from their IP server-side (the browser never gets or sends location data).
//
// Deploy:  supabase functions deploy track-visit --no-verify-jwt
// Called by: site/visit.js (public site, anon, no login)
// Body: { "page": "/...", "visitor": "<random id from localStorage>", "referrer": "..." }
import { createClient } from "npm:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

function clientIp(req: Request): string {
  // Supabase's edge runtime sets x-forwarded-for to "<client>, <proxy1>, ...";
  // the first entry is the actual visitor.
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) return fwd.split(",")[0].trim();
  return req.headers.get("x-real-ip") ?? "";
}

function isPrivateIp(ip: string): boolean {
  return !ip || ip === "127.0.0.1" || ip === "::1" ||
    /^10\./.test(ip) || /^192\.168\./.test(ip) || /^172\.(1[6-9]|2\d|3[0-1])\./.test(ip);
}

async function cityFor(ip: string): Promise<string | null> {
  if (isPrivateIp(ip)) return null;
  try {
    const ctrl = new AbortController();
    const timeout = setTimeout(() => ctrl.abort(), 2500);
    // Free tier, http-only, no key needed; low volume (pre-launch site) stays well under its limit.
    const r = await fetch(`http://ip-api.com/json/${ip}?fields=status,city`, { signal: ctrl.signal });
    clearTimeout(timeout);
    if (!r.ok) return null;
    const j = await r.json();
    return j.status === "success" && j.city ? String(j.city) : null;
  } catch (_) {
    return null; // geo lookup is a nice-to-have; never block logging the visit over it
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body: { page?: string; visitor?: string; referrer?: string };
  try {
    body = await req.json();
  } catch (_) {
    return json({ error: "bad json" }, 400);
  }
  if (!body.visitor) return json({ error: "missing visitor" }, 400);

  const city = await cityFor(clientIp(req));

  const { error } = await admin.rpc("track_site_visit", {
    p_page: body.page ?? null,
    p_visitor: body.visitor,
    p_referrer: body.referrer ?? null,
    p_city: city,
  });
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
});
