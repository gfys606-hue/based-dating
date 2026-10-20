// Stripe → Based: keeps memberships in step with subscriptions (new, renewed, changed, cancelled, failed).
//
// In Stripe → Developers → Webhooks, point an endpoint at
//   https://<project>.supabase.co/functions/v1/stripe-webhook
// with events: customer.subscription.created, customer.subscription.updated, customer.subscription.deleted,
//              checkout.session.completed (gifts)
//
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
//          STRIPE_PRICE_PREMIUM_MONTH, STRIPE_PRICE_PREMIUM_YEAR (older Plus/Inner prices still count as Premium)
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "");

function tierForPrice(priceId: string | undefined): "premium" | "plus" | "inner" | null {
  if (!priceId) return null;
  if ([Deno.env.get("STRIPE_PRICE_PREMIUM_MONTH"), Deno.env.get("STRIPE_PRICE_PREMIUM_YEAR")].includes(priceId)) return "premium";
  if ([Deno.env.get("STRIPE_PRICE_INNER_MONTH"), Deno.env.get("STRIPE_PRICE_INNER_YEAR")].includes(priceId)) return "inner";
  if ([Deno.env.get("STRIPE_PRICE_PLUS_MONTH"), Deno.env.get("STRIPE_PRICE_PLUS_YEAR")].includes(priceId)) return "plus";
  return null;
}

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig ?? "", Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "");
  } catch (e) {
    return new Response(`bad signature: ${(e as Error).message}`, { status: 400 });
  }

  // A paid gift: deliver it into the chat
  if (event.type === "checkout.session.completed") {
    const s = event.data.object as Stripe.Checkout.Session;
    if (s.metadata?.kind !== "gift" || !s.metadata?.send_id) return new Response("ignored");
    if (s.payment_status !== "paid") return new Response("not paid yet");
    const { error } = await admin.rpc("deliver_gift", { p_send: s.metadata.send_id, p_paid_cents: s.amount_total ?? 0 });
    if (error) return new Response(error.message, { status: 500 });
    return new Response("ok");
  }

  if (!event.type.startsWith("customer.subscription.")) return new Response("ignored");

  const sub = event.data.object as Stripe.Subscription;
  const customer = typeof sub.customer === "string" ? sub.customer : sub.customer.id;
  let userId = sub.metadata?.user_id as string | undefined;
  if (!userId) {
    const { data } = await admin.rpc("user_for_stripe_customer", { p_customer: customer });
    userId = (data as string | null) ?? undefined;
  }
  if (!userId) return new Response("no user for this customer", { status: 200 });

  const item = sub.items.data[0];
  const tier = tierForPrice(item?.price?.id) ?? (sub.metadata?.tier as "premium" | "plus" | "inner" | undefined) ?? "premium";
  const periodEnd = (item as unknown as { current_period_end?: number })?.current_period_end
    ?? (sub as unknown as { current_period_end?: number }).current_period_end;

  const status = event.type === "customer.subscription.deleted" || ["canceled", "unpaid", "incomplete_expired"].includes(sub.status)
    ? "canceled"
    : sub.status === "past_due" ? "past_due" : "active";

  const { error } = await admin.rpc("apply_subscription", {
    p_user: userId,
    p_tier: tier,
    p_status: status,
    p_period_end: status === "canceled" ? new Date().toISOString() : periodEnd ? new Date(periodEnd * 1000).toISOString() : null,
    p_cancel_at_end: sub.cancel_at_period_end ?? false,
    p_customer: customer,
    p_subscription: sub.id,
  });
  if (error) return new Response(error.message, { status: 500 });
  return new Response("ok");
});
