// AI photo check. Called by the app right after a selfie or photo upload.
//   selfie : must contain exactly one live face  → set_selfie_verified
//   photo  : must contain the verified user (face match against the selfie)
//            photos 1-3 must also be a clear, camera-facing, solo face shot
//
// Uses AWS Rekognition (DetectFaces + CompareFaces). Any provider works —
// swap the two helper functions below.
//
// Deploy:  supabase functions deploy photo-check
// Secrets: supabase secrets set AWS_REGION=ca-central-1 AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  CompareFacesCommand,
  DetectFacesCommand,
  RekognitionClient,
} from "npm:@aws-sdk/client-rekognition@3";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const rek = new RekognitionClient({ region: Deno.env.get("AWS_REGION") ?? "ca-central-1" });

async function download(bucket: string, path: string): Promise<Uint8Array> {
  const { data, error } = await admin.storage.from(bucket).download(path);
  if (error) throw error;
  return new Uint8Array(await data.arrayBuffer());
}

// Clear face = one dominant face, looking roughly at the camera, eyes open, no sunglasses, sharp.
async function analyse(bytes: Uint8Array) {
  const out = await rek.send(new DetectFacesCommand({ Image: { Bytes: bytes }, Attributes: ["ALL"] }));
  const faces = (out.FaceDetails ?? []).filter((f) => (f.Confidence ?? 0) > 90);
  const main = faces.sort((a, b) =>
    (b.BoundingBox!.Width! * b.BoundingBox!.Height!) - (a.BoundingBox!.Width! * a.BoundingBox!.Height!)
  )[0];
  if (!main) return { faces: 0, clear: false };
  const p = main.Pose!;
  const clear =
    Math.abs(p.Yaw!) < 30 && Math.abs(p.Pitch!) < 25 &&
    !(main.Sunglasses?.Value) &&
    (main.EyesOpen?.Value ?? true) &&
    (main.Quality?.Sharpness ?? 100) > 40 &&
    main.BoundingBox!.Width! > 0.12;           // not a tiny distant face
  return { faces: faces.length, clear };
}

async function sameFace(selfie: Uint8Array, photo: Uint8Array): Promise<boolean> {
  const out = await rek.send(new CompareFacesCommand({
    SourceImage: { Bytes: selfie }, TargetImage: { Bytes: photo }, SimilarityThreshold: 90,
  }));
  return (out.FaceMatches ?? []).length > 0;
}

Deno.serve(async (req) => {
  // Identify the caller from their JWT
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return new Response("unauthorized", { status: 401 });

  const body = await req.json() as { type: "selfie" | "photo"; photo_id?: string };

  const { data: profile } = await admin.from("profiles").select("selfie_path").eq("id", user.id).single();
  if (!profile?.selfie_path) return new Response("no selfie", { status: 400 });
  const selfie = await download("selfies", profile.selfie_path);

  if (body.type === "selfie") {
    const a = await analyse(selfie);
    const ok = a.faces === 1 && a.clear;
    await admin.rpc("set_selfie_verified", { p_user: user.id, p_ok: ok });
    return Response.json({ ok, reason: ok ? null : "Take a clear selfie, alone, facing the camera." });
  }

  const { data: photo } = await admin.from("photos").select("*").eq("id", body.photo_id).eq("user_id", user.id).single();
  if (!photo) return new Response("no photo", { status: 404 });
  const bytes = await download("photos", photo.storage_path);

  const a = await analyse(bytes);
  // Photos 4-6 may show the user facing away. Face match can't confirm those,
  // so they go to human review (shows_user = null → stays pending) unless a face matches.
  let showsUser = a.faces > 0 ? await sameFace(selfie, bytes) : false;
  const clearFace = showsUser && a.clear && a.faces === 1;

  if (photo.position >= 4 && a.faces === 0) {
    // No visible face: could be back-of-head (allowed) or a mountain (not allowed).
    // Leave pending for a moderator to decide.
    return Response.json({ status: "pending_review" });
  }
  if (photo.position <= 3 && a.faces === 0) showsUser = false;

  const reason = !showsUser
    ? "This photo needs to clearly be you."
    : (photo.position <= 3 && !clearFace)
    ? "Photos 1-3 must be just you, looking at the camera, face clearly visible."
    : null;

  await admin.rpc("set_photo_review", {
    p_photo: photo.id, p_shows_user: showsUser, p_clear_face: clearFace, p_reason: reason,
  });
  return Response.json({ approved: reason === null, reason });
});
