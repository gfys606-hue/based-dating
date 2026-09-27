// Gives a signed-in user a LiveKit token for their scheduled call.
//
// Deploy:  supabase functions deploy call-token
// Secrets: supabase secrets set LIVEKIT_URL=wss://<project>.livekit.cloud LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=...
//
// Body: { "call_id": "<uuid>" }  ->  { "url": "wss://...", "token": "<jwt>" }
import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken, RoomServiceClient } from "npm:livekit-server-sdk@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const LK_URL = Deno.env.get("LIVEKIT_URL") ?? "";
const LK_KEY = Deno.env.get("LIVEKIT_API_KEY") ?? "";
const LK_SECRET = Deno.env.get("LIVEKIT_API_SECRET") ?? "";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!LK_URL || !LK_KEY || !LK_SECRET) return json({ error: "Calls aren't set up yet." }, 503);

  // Who is calling?
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: auth } = await admin.auth.getUser(jwt);
  const user = auth?.user;
  if (!user) return json({ error: "Please log in again." }, 401);

  const { call_id } = await req.json().catch(() => ({}));
  if (!call_id) return json({ error: "Missing call." }, 400);

  const { data: verdict, error } = await admin.rpc("can_join_call", { p_call: call_id, p_user: user.id });
  if (error) return json({ error: error.message }, 400);
  if (verdict !== "ok") return json({ error: verdict }, 403);

  const room = `call_${call_id}`;
  // Close the room ~20s after the last person leaves, so the call gets scored quickly.
  try {
    const rooms = new RoomServiceClient(LK_URL.replace(/^wss?:/, "https:"), LK_KEY, LK_SECRET);
    await rooms.createRoom({ name: room, emptyTimeout: 300, departureTimeout: 20, maxParticipants: 2 });
  } catch (_) {
    // Room may already exist; joining still works.
  }

  const at = new AccessToken(LK_KEY, LK_SECRET, { identity: user.id, ttl: "3h" });
  at.addGrant({ roomJoin: true, room, canPublish: true, canSubscribe: true, canPublishData: false });
  return json({ url: LK_URL, token: await at.toJwt() });
});
