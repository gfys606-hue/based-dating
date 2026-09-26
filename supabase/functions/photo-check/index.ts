// Photo check. Called by the app right after a selfie or photo upload.
//
// Two modes:
//  * AI mode (when AWS_ACCESS_KEY_ID is set): AWS Rekognition checks that the
//    selfie is one clear face, and that each photo shows the same person
//    (photos 1-3 must be a clear, camera-facing, solo face shot).
//  * Manual mode (no AWS keys yet, the free default): everything is approved
//    so people can finish signing up, and every image is added to
//    public.manual_review for a person to check in the Supabase Table Editor.
//
// Deploy: Supabase dashboard → Edge Functions → photo-check (or `supabase functions deploy photo-check`)
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const AI = !!Deno.env.get("AWS_ACCESS_KEY_ID");

async function download(bucket: string, path: string): Promise<Uint8Array> {
  const { data, error } = await admin.storage.from(bucket).download(path);
  if (error) throw error;
  return new Uint8Array(await data.arrayBuffer());
}

// ---------- AI helpers (only loaded when AWS keys exist) ----------
async function rekognition() {
  const m = await import("npm:@aws-sdk/client-rekognition@3");
  return { m, client: new m.RekognitionClient({ region: Deno.env.get("AWS_REGION") ?? "ca-central-1" }) };
}

async function analyse(bytes: Uint8Array) {
  const { m, client } = await rekognition();
  const out = await client.send(new m.DetectFacesCommand({ Image: { Bytes: bytes }, Attributes: ["ALL"] }));
  // deno-lint-ignore no-explicit-any
  const faces = (out.FaceDetails ?? []).filter((f: any) => (f.Confidence ?? 0) > 90);
  // deno-lint-ignore no-explicit-any
  const main: any = faces.sort((a: any, b: any) =>
    (b.BoundingBox.Width * b.BoundingBox.Height) - (a.BoundingBox.Width * a.BoundingBox.Height)
  )[0];
  if (!main) return { faces: 0, clear: false };
  const p = main.Pose;
  const clear = Math.abs(p.Yaw) < 30 && Math.abs(p.Pitch) < 25 && !(main.Sunglasses?.Value) &&
    (main.EyesOpen?.Value ?? true) && (main.Quality?.Sharpness ?? 100) > 40 && main.BoundingBox.Width > 0.12;
  return { faces: faces.length, clear };
}

async function sameFace(selfie: Uint8Array, photo: Uint8Array) {
  const { m, client } = await rekognition();
  const out = await client.send(new m.CompareFacesCommand({
    SourceImage: { Bytes: selfie }, TargetImage: { Bytes: photo }, SimilarityThreshold: 90,
  }));
  return (out.FaceMatches ?? []).length > 0;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
    const { data: { user } } = await admin.auth.getUser(jwt);
    if (!user) return json({ error: "Not signed in" }, 401);

    const body = await req.json() as { type: "selfie" | "photo"; photo_id?: string };

    // ---------------- selfie ----------------
    if (body.type === "selfie") {
      if (!AI) {
        await admin.rpc("set_selfie_verified", { p_user: user.id, p_ok: true });
        await admin.from("manual_review").insert({ user_id: user.id, kind: "selfie" });
        return json({ ok: true, mode: "manual" });
      }
      const { data: profile } = await admin.from("profiles").select("selfie_path").eq("id", user.id).single();
      if (!profile?.selfie_path) return json({ ok: false, reason: "No selfie uploaded." }, 400);
      const a = await analyse(await download("selfies", profile.selfie_path));
      const ok = a.faces === 1 && a.clear;
      await admin.rpc("set_selfie_verified", { p_user: user.id, p_ok: ok });
      return json({ ok, reason: ok ? null : "Take a clear selfie, alone, facing the camera." });
    }

    // ---------------- photo ----------------
    const { data: photo } = await admin.from("photos").select("*").eq("id", body.photo_id).eq("user_id", user.id).single();
    if (!photo) return json({ error: "Photo not found" }, 404);

    if (!AI) {
      await admin.rpc("set_photo_review", { p_photo: photo.id, p_shows_user: true, p_clear_face: true, p_reason: null });
      await admin.from("manual_review").insert({ user_id: user.id, photo_id: photo.id, kind: "photo" });
      return json({ approved: true, mode: "manual" });
    }

    const { data: profile } = await admin.from("profiles").select("selfie_path").eq("id", user.id).single();
    const selfie = await download("selfies", profile!.selfie_path);
    const bytes = await download("photos", photo.storage_path);
    const a = await analyse(bytes);
    if (photo.position >= 4 && a.faces === 0) {
      await admin.from("manual_review").insert({ user_id: user.id, photo_id: photo.id, kind: "photo" });
      return json({ status: "pending_review" });
    }
    const showsUser = a.faces > 0 ? await sameFace(selfie, bytes) : false;
    const clearFace = showsUser && a.clear && a.faces === 1;
    const reason = !showsUser
      ? "This photo needs to clearly be you."
      : (photo.position <= 3 && !clearFace)
      ? "Photos 1-3 must be just you, looking at the camera, face clearly visible."
      : null;
    await admin.rpc("set_photo_review", { p_photo: photo.id, p_shows_user: showsUser, p_clear_face: clearFace, p_reason: reason });
    return json({ approved: reason === null, reason });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
