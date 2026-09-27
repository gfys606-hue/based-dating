// Receives LiveKit webhooks and applies the call rules (5-minute minimum, reschedules, etc.).
// Nothing is recorded: only who joined/left and when.
//
// Deploy:  supabase functions deploy livekit-webhook --no-verify-jwt
// LiveKit Cloud → Settings → Webhooks → add https://<project-ref>.supabase.co/functions/v1/livekit-webhook
// Uses the same LIVEKIT_API_KEY / LIVEKIT_API_SECRET secrets as call-token.
import { createClient } from "npm:@supabase/supabase-js@2";
import { WebhookReceiver } from "npm:livekit-server-sdk@2";

const receiver = new WebhookReceiver(Deno.env.get("LIVEKIT_API_KEY") ?? "", Deno.env.get("LIVEKIT_API_SECRET") ?? "");
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const CLIENT_INITIATED = 1; // LiveKit DisconnectReason.CLIENT_INITIATED

Deno.serve(async (req) => {
  const body = await req.text();
  let event;
  try {
    event = await receiver.receive(body, req.headers.get("Authorization") ?? undefined);
  } catch (_) {
    return new Response("unauthorized", { status: 401 });
  }

  const roomName = event.room?.name ?? "";
  if (!roomName.startsWith("call_")) return new Response("ignored");
  const callId = roomName.slice("call_".length);
  const identity = event.participant?.identity;

  let error;
  switch (event.event) {
    case "participant_joined":
      ({ error } = await admin.rpc("livekit_participant", { p_call: callId, p_user: identity, p_joined: true }));
      break;
    case "participant_left": {
      const reason = event.participant?.disconnectReason as unknown;
      const drop = !(reason === CLIENT_INITIATED || reason === "CLIENT_INITIATED");
      ({ error } = await admin.rpc("livekit_participant", {
        p_call: callId, p_user: identity, p_joined: false, p_drop: drop,
      }));
      break;
    }
    case "room_finished":
      ({ error } = await admin.rpc("livekit_room_finished", { p_call: callId }));
      break;
  }
  if (error) return new Response(error.message, { status: 400 });
  return new Response("ok");
});
