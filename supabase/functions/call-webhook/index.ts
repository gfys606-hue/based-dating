// Receives "call ended" events from the video/voice provider (LiveKit, Daily, Agora…)
// and applies the call rules in the database (5-min minimum, reschedules, etc.).
//
// Deploy:  supabase functions deploy call-webhook --no-verify-jwt
// Secrets: supabase secrets set CALL_WEBHOOK_SECRET=<long random string>
//
// Expected JSON body (map your provider's webhook payload to this shape):
// { "call_id": "<uuid>", "kind": "voice"|"video", "duration_seconds": 412,
//   "ended_by": "<user uuid or null>", "end_reason": "normal"|"early"|"report"|"connection" }
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("CALL_WEBHOOK_SECRET")) {
    return new Response("unauthorized", { status: 401 });
  }
  const e = await req.json();
  const reason = e.duration_seconds >= 300 ? "normal" : (e.end_reason ?? "early");

  const { data, error } = await supabase.rpc("complete_call", {
    p_call: e.call_id,
    p_kind: e.kind,
    p_duration_seconds: e.duration_seconds,
    p_ended_by: e.ended_by ?? null,
    p_end_reason: reason,
  });
  if (error) return new Response(error.message, { status: 400 });
  return Response.json({ result: data });
});
