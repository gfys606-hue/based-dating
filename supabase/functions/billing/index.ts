// Membership checkout and "manage membership" links (Stripe).
//
// The app calls this signed in. Body: { "action": "checkout", "tier": "plus"|"inner", "period": "month"|"year" }
//                                  or { "action": "portal" }
// Returns { url } to open in the browser.
//
// Secrets (set by the owner in Supabase → Edge Functions → Secrets):
//   STRIPE_SECRET_KEY
//   STRIPE_PRICE_PLUS_MONTH, STRIPE_PRICE_PLUS_YEAR, STRIPE_PRICE_INNER_MONTH, STRIPE_PRICE_INNER_YEAR
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
  const back = Deno.env.get("BILLING_RETURN_URL") ?? "https://based-social.com";

  const { data: existing } = await admin.rpc("stripe_customer_for", { p_user: user.id });
  let customer = existing as string | null;

  if (body.action === "portal") {
    if (!customer) return json({ error: "No membership to manage yet." }, 400);
    const s = await stripe.billingPortal.sessions.create({ customer, return_url: back });
    return json({ url: s.url });
  }

  const tier = body.tier === "inner" ? "inner" : "plus";
  const p = price(tier, body.period);
  if (!p) return json({ error: "That plan isn't set up yet." }, 503);

  if (!customer) {
    const c = await stripe.customers.create({ email: user.email ?? undefined, metadata: { user_id: user.id } });
    customer = c.id;
  }

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
