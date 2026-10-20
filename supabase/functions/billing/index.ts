// Membership checkout and "manage membership" links (Stripe).
//
// The app calls this signed in. Body: { "action": "checkout", "tier": "premium", "period": "month"|"year" }
//                                  or { "action": "gift", "match": "<match id>", "gift": "round", "note": "..." }
//                                  or { "action": "portal" }
// Returns { url } to open in the browser.
//
// Secrets (set by the owner in Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY
//   STRIPE_PRICE_PREMIUM_MONTH, STRIPE_PRICE_PREMIUM_YEAR   (one plan for the whole platform)
//   Gifts need no price setup: each is charged at its catalog price (gift_catalog), in CAD.
//   BILLING_RETURN_URL   (optional, default https://based-social.com)
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function price(tier: string, period: string): string | undefined {
  const key = `STRIPE_PRICE_${tier.toUpperCase()}_${period === "year" ? "YEAR" : "MONTH"}`;
  return Deno.env.get(key);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  const secret = Deno.env.get("STRIPE_SECRET_KEY");
  if (!secret) return json({ error: "Memberships aren't open yet." }, 503);
  const stripe = new Stripe(secret);

  // Who's asking
  const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "Sign in first." }, 401);

  const body = await req.json().catch(() => ({}));

  // Paid tiers are switched on in The door. Until then nobody can be charged.
  const { data: open } = await admin.rpc("memberships_open");
  if (open !== true && body.action !== "portal") return json({ error: "Everything's free during early access." }, 409);
  const back = Deno.env.get("BILLING_RETURN_URL") ?? "https://based-social.com";

  const { data: existing } = await admin.rpc("stripe_customer_for", { p_user: user.id });
  let customer = existing as string | null;

  if (body.action === "portal") {
    if (!customer) return json({ error: "No membership to manage yet." }, 400);
    const s = await stripe.billingPortal.sessions.create({ customer, return_url: back });
    return json({ url: s.url });
  }

  if (!customer) {
    const c = await stripe.customers.create({ email: user.email ?? undefined, metadata: { user_id: user.id } });
    customer = c.id;
  }

  // A gift: one-time payment. The gift is delivered by stripe-webhook once it's paid.
  if (body.action === "gift") {
    const { data: g, error } = await admin.rpc("prepare_gift", {
      p_user: user.id, p_match: body.match, p_gift: body.gift, p_note: body.note ?? null,
    });
    if (error || !g) return json({ error: error?.message ?? "Couldn't start that gift." }, 400);
    const gift = g as { send_id: string; name: string; price_cents: number };
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      customer,
      line_items: [{
        quantity: 1,
        price_data: { currency: "cad", unit_amount: gift.price_cents, product_data: { name: `Gift: ${gift.name}` } },
      }],
      client_reference_id: user.id,
      metadata: { user_id: user.id, kind: "gift", send_id: gift.send_id },
      payment_intent_data: { metadata: { kind: "gift", send_id: gift.send_id } },
      success_url: `${back}/?gift=sent`,
      cancel_url: `${back}/?gift=cancelled`,
    });
    return json({ url: session.url });
  }

  const tier = "premium";
  const p = price(tier, body.period);
  if (!p) return json({ error: "That plan isn't set up yet." }, 503);

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer,
    line_items: [{ price: p, quantity: 1 }],
    client_reference_id: user.id,
    subscription_data: { metadata: { user_id: user.id, tier } },
    metadata: { user_id: user.id, tier },
    allow_promotion_codes: true,
    success_url: `${back}/?membership=thanks`,
    cancel_url: `${back}/?membership=cancelled`,
  });
  return json({ url: session.url });
});
