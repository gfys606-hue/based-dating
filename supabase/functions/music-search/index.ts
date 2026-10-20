// Music search for venue suggestions (Deezer's free public API, no key needed).
//
// The web app calls this (browsers can't call Deezer directly); the phone app calls Deezer itself.
// Body: { "q": "song or artist", "type": "track" | "album" }      → { results: [...] }
//    or { "preview": 12345, "type": "track" | "album" }         → { preview: "https://…mp3" } (fresh 30-sec clip)
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type Hit = { kind: string; id: number; title: string; artist: string; cover: string | null; preview: string | null; link: string | null };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  const body = await req.json().catch(() => ({}));
  const type = body.type === "album" ? "album" : "track";
  try {
    if (body.preview) {
      const id = Number(body.preview);
      if (!Number.isFinite(id)) return json({ error: "Bad id" }, 400);
      if (type === "album") {
        const r = await fetch(`https://api.deezer.com/album/${id}/tracks?limit=1`).then((x) => x.json());
        return json({ preview: r?.data?.[0]?.preview || null });
      }
      const r = await fetch(`https://api.deezer.com/track/${id}`).then((x) => x.json());
      return json({ preview: r?.preview || null });
    }

    const q = String(body.q ?? "").trim().slice(0, 100);
    if (q.length < 2) return json({ results: [] });
    const r = await fetch(`https://api.deezer.com/search/${type}?q=${encodeURIComponent(q)}&limit=15`).then((x) => x.json());
    const results: Hit[] = (r?.data ?? []).map((d: Record<string, any>) => ({
      kind: type,
      id: d.id,
      title: d.title,
      artist: d.artist?.name ?? "",
      cover: (type === "album" ? d.cover_medium : d.album?.cover_medium) ?? null,
      preview: type === "track" ? d.preview || null : null,
      link: d.link ?? null,
    }));
    return json({ results });
  } catch (e) {
    return json({ error: `Music search is down right now. ${(e as Error).message}` }, 502);
  }
});
