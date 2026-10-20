-- One premium tier for the whole platform, plus gifts (priority 3, Oct 19 2026).
--
--   Premium  (one plan, dating + social): 50 Ouch picks a day · rewind (undo a pass) · travel mode
--            · read receipts · extra Unedited voice prompts + one swap per question · app themes
--            · 2 extra personal invites a month · the premium mark (only other premium members see it).
--   Free     basic profile editing and everything that helps you meet people.
--   Gifts    sold separately, one at a time (never part of a plan).
--
-- While paid memberships are switched off (early access) everyone gets the premium perks free and
-- gifts are free too (3 a day). Old Plus / Inner rows count as Premium.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- The tier
-- ---------------------------------------------------------------------
alter table public.memberships drop constraint if exists memberships_tier_check;
alter table public.memberships add constraint memberships_tier_check check (tier in ('plus','inner','premium'));

create or replace function public.membership_tier(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when exists (
    select 1 from memberships m
     where m.user_id = p_user
       and m.status in ('active','past_due')
       and (m.current_period_end is null or m.current_period_end > now())) then 'premium' else 'free' end;
$$;

-- premium perks: real premium, or anyone while paid plans are off
create or replace function public.has_premium(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select not memberships_open() or membership_tier(p_user) = 'premium';
$$;

create or replace function public.apply_subscription(
  p_user uuid, p_tier text, p_status text, p_period_end timestamptz,
  p_cancel_at_end boolean, p_customer text, p_subscription text)
returns void language plpgsql security definer set search_path = public as $$
declare
  was text := membership_tier(p_user);
begin
  if p_tier not in ('plus','inner','premium') then raise exception 'Unknown tier'; end if;
  insert into memberships (user_id, tier, source, status, current_period_end, cancel_at_period_end, stripe_customer, stripe_subscription, updated_at)
  values (p_user, 'premium', 'stripe', p_status, p_period_end, coalesce(p_cancel_at_end, false), p_customer, p_subscription, now())
  on conflict (user_id) do update
     set tier = 'premium', source = 'stripe', status = excluded.status,
         current_period_end = excluded.current_period_end, cancel_at_period_end = excluded.cancel_at_period_end,
         stripe_customer = coalesce(excluded.stripe_customer, memberships.stripe_customer),
         stripe_subscription = coalesce(excluded.stripe_subscription, memberships.stripe_subscription),
         updated_at = now();
  perform after_tier_change(p_user, was);
end $$;

create or replace function public.admin_grant_membership(p_user uuid, p_tier text, p_days int default 30)
returns void language plpgsql security definer set search_path = public as $$
declare
  was text;
begin
  perform require_admin();
  was := membership_tier(p_user);
  if p_tier = 'free' then
    delete from memberships where user_id = p_user and source = 'admin';
  else
    if p_tier not in ('plus','inner','premium') then raise exception 'Unknown tier'; end if;
    insert into memberships (user_id, tier, source, status, current_period_end)
    values (p_user, 'premium', 'admin', 'active', now() + make_interval(days => greatest(1, coalesce(p_days, 30))))
    on conflict (user_id) do update
       set tier = 'premium', source = 'admin', status = 'active',
           current_period_end = excluded.current_period_end, cancel_at_period_end = false, updated_at = now();
  end if;
  perform after_tier_change(p_user, was);
end $$;

update public.memberships set tier = 'premium' where tier in ('plus','inner');

create or replace function public.refill_inner_invites()
returns void language sql security definer set search_path = public as $$
  select grant_inner_bonus(m.user_id) from memberships m where membership_tier(m.user_id) = 'premium';
$$;

create or replace function public.after_tier_change(p_user uuid, p_was text)
returns void language plpgsql security definer set search_path = public as $$
declare
  now_tier text := membership_tier(p_user);
begin
  if now_tier = 'premium' and p_was <> 'premium' then
    perform grant_inner_bonus(p_user);
    perform notify(p_user, 'membership', 'Premium is on. Two extra invites are waiting for you.');
  end if;
  if memberships_open() and now_tier <> 'premium' then perform end_travel_for(p_user); end if;
end $$;

create or replace function public.undo_last_pass()
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_to uuid;
begin
  if not has_premium(me) then raise exception 'Rewind comes with Premium.'; end if;
  select to_user into v_to from passes
   where from_user = me and created_at > now() - interval '1 day'
   order by created_at desc limit 1;
  if v_to is null then return null; end if;
  delete from passes where from_user = me and to_user = v_to;
  return v_to;
end $$;

create or replace function public.inner_mark(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select membership_tier(auth.uid()) = 'premium' and membership_tier(p_user) = 'premium' and p_user <> auth.uid();
$$;

create or replace function public.my_membership()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tier', membership_tier(auth.uid()),
    'premium', has_premium(auth.uid()),
    'open', memberships_open(),
    'source', m.source, 'status', m.status,
    'renews', case when m.cancel_at_period_end then null else m.current_period_end end,
    'ends',   case when m.cancel_at_period_end then m.current_period_end else null end,
    'has_billing', m.stripe_customer is not null,
    'daily_picks', daily_pick_cap(auth.uid()),
    'travel', (select case when p.travel_until > now()
                 then jsonb_build_object('name', p.travel_name, 'until', p.travel_until) end
               from profiles p where p.id = auth.uid()))
  from (select 1) one left join memberships m on m.user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- Read receipts (only premium senders see "Seen")
-- ---------------------------------------------------------------------
alter table public.messages add column if not exists read_at timestamptz;

create or replace function public.mark_match_read(p_match uuid)
returns void language sql security definer set search_path = public as $$
  update messages set read_at = now()
   where match_id = p_match and sender_id <> auth.uid() and read_at is null and status = 'sent'
     and exists (select 1 from matches m where m.id = p_match and auth.uid() in (m.user_a, m.user_b));
$$;

-- ---------------------------------------------------------------------
-- Unedited: extra voice prompts for premium, and one swap per question
-- ---------------------------------------------------------------------
alter table public.voice_questions add column if not exists premium boolean not null default false;
alter table public.voice_draws add column if not exists swapped boolean not null default false;

insert into public.voice_questions (text, premium) values
  ('What''s a song that takes you straight back to somewhere?', true),
  ('What''s the most spontaneous thing you''ve ever done?', true),
  ('Tell me about a place you could go back to every year.', true),
  ('What''s something you''re quietly proud of?', true),
  ('What does a perfect Friday night look like for you?', true),
  ('What''s a hill you''ll happily die on?', true),
  ('What''s the best advice you ignored?', true),
  ('What are you weirdly good at?', true),
  ('Describe your ideal first drink with someone new.', true),
  ('What''s something you want to learn this year?', true)
on conflict (text) do update set premium = true;

create or replace function public.draw_voice_question()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  last_at timestamptz;
  d voice_draws;
  q voice_questions;
  v_premium boolean := has_premium(auth.uid());
begin
  if me is null then raise exception 'Please log in again.'; end if;
  select created_at into last_at from voice_answers where user_id = me;
  if last_at is not null and last_at > now() - interval '24 hours' then
    raise exception 'You can answer a new question in % hours.',
      greatest(1, ceil(extract(epoch from last_at + interval '24 hours' - now()) / 3600))::int;
  end if;

  select * into d from voice_draws where user_id = me;
  if d.user_id is not null and d.drawn_at > now() - interval '10 minutes' then
    select * into q from voice_questions where id = d.question_id;
  else
    select * into q from voice_questions
     where id is distinct from (select question_id from voice_answers where user_id = me)
       and (v_premium or not premium)
     order by random() limit 1;
    insert into voice_draws (user_id, question_id, drawn_at, swapped) values (me, q.id, now(), false)
    on conflict (user_id) do update set question_id = excluded.question_id, drawn_at = now(), swapped = false;
    d.swapped := false;
  end if;
  return jsonb_build_object('id', q.id, 'text', q.text,
    'can_swap', v_premium and not coalesce(d.swapped, false), 'premium', v_premium);
end $$;

-- Premium: don't like the question? One swap per draw.
create or replace function public.swap_voice_question()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d voice_draws;
  q voice_questions;
begin
  if not has_premium(me) then raise exception 'Swapping questions comes with Premium.'; end if;
  select * into d from voice_draws where user_id = me;
  if d.user_id is null or d.drawn_at < now() - interval '10 minutes' then return draw_voice_question(); end if;
  if d.swapped then raise exception 'You''ve already swapped this one.'; end if;
  select * into q from voice_questions
   where id <> d.question_id
     and id is distinct from (select question_id from voice_answers where user_id = me)
   order by random() limit 1;
  update voice_draws set question_id = q.id, drawn_at = now(), swapped = true where user_id = me;
  return jsonb_build_object('id', q.id, 'text', q.text, 'can_swap', false, 'premium', true);
end $$;

-- ---------------------------------------------------------------------
-- Gifts: one-time purchases, sent into a match chat
-- ---------------------------------------------------------------------
create table if not exists public.gift_catalog (
  code        text primary key,
  name        text not null,
  icon        text not null,          -- Material icon name the app draws
  price_cents int  not null check (price_cents between 50 and 10000),
  sort        int  not null default 100,
  active      boolean not null default true
);
alter table public.gift_catalog enable row level security;
drop policy if exists "gift catalog read" on public.gift_catalog;
create policy "gift catalog read" on public.gift_catalog for select to authenticated using (active);
grant select on public.gift_catalog to authenticated;

insert into public.gift_catalog (code, name, icon, price_cents, sort) values
  ('round',  'A round on me',     'local_bar',     499, 1),
  ('rose',   'A rose',            'local_florist', 199, 2),
  ('record', 'A record for you',  'album',         299, 3),
  ('coffee', 'Coffee tomorrow?',  'coffee',        199, 4)
on conflict (code) do nothing;

create table if not exists public.gift_sends (
  id             uuid primary key default gen_random_uuid(),
  from_user      uuid not null references public.profiles(id) on delete cascade,
  to_user        uuid not null references public.profiles(id) on delete cascade,
  match_id       uuid references public.matches(id) on delete set null,
  gift           text not null references public.gift_catalog(code),
  note           text check (char_length(note) <= 140),
  status         text not null default 'pending' check (status in ('pending','sent')),
  paid_cents     int not null default 0,
  stripe_session text,
  created_at     timestamptz not null default now(),
  sent_at        timestamptz
);
alter table public.gift_sends enable row level security;  -- functions only
create index if not exists gift_sends_from on public.gift_sends (from_user, created_at);

alter table public.messages add column if not exists gift text references public.gift_catalog(code);
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (kind in ('text','voice','gift'));

-- Puts the gift in the chat and tells them
create or replace function public.deliver_gift(p_send uuid, p_paid_cents int default 0)
returns void language plpgsql security definer set search_path = public as $$
declare
  g gift_sends;
  c gift_catalog;
begin
  select * into g from gift_sends where id = p_send for update;
  if g.id is null or g.status = 'sent' then return; end if;
  select * into c from gift_catalog where code = g.gift;
  update gift_sends set status = 'sent', sent_at = now(), paid_cents = coalesce(p_paid_cents, 0) where id = g.id;
  if g.match_id is not null then
    perform set_config('based.gift', 'on', true);
    insert into messages (match_id, sender_id, body, kind, gift)
    values (g.match_id, g.from_user, left(c.name || coalesce(': ' || nullif(btrim(g.note), ''), ''), 2000), 'gift', g.gift);
    perform set_config('based.gift', '', true);
  end if;
  perform notify(g.to_user, 'gift', (select display_name from profiles where id = g.from_user) || ' sent you ' || lower(c.name) || '.');
end $$;

-- The app asks to send a gift. Free (3 a day) during early access; otherwise it's paid through checkout.
create or replace function public.send_gift(p_match uuid, p_gift text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m matches;
  v uuid;
begin
  select * into m from matches where id = p_match;
  if m.id is null or me not in (m.user_a, m.user_b) or m.status <> 'active' then raise exception 'That chat isn''t open.'; end if;
  if not exists (select 1 from gift_catalog where code = p_gift and active) then raise exception 'Pick a gift.'; end if;
  if memberships_open() then
    return jsonb_build_object('checkout', true);   -- app opens checkout through the billing function
  end if;
  if (select count(*) from gift_sends where from_user = me and created_at > now() - interval '1 day') >= 3 then
    raise exception 'Three gifts a day during early access. More tomorrow.';
  end if;
  insert into gift_sends (from_user, to_user, match_id, gift, note)
  values (me, case when m.user_a = me then m.user_b else m.user_a end, m.id, p_gift, left(nullif(btrim(p_note), ''), 140))
  returning id into v;
  perform deliver_gift(v, 0);
  return jsonb_build_object('sent', true);
end $$;

-- Billing function (service role): make a pending gift for checkout
create or replace function public.prepare_gift(p_user uuid, p_match uuid, p_gift text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m matches;
  c gift_catalog;
  v uuid;
begin
  select * into m from matches where id = p_match;
  if m.id is null or p_user not in (m.user_a, m.user_b) or m.status <> 'active' then raise exception 'That chat isn''t open.'; end if;
  select * into c from gift_catalog where code = p_gift and active;
  if c.code is null then raise exception 'Pick a gift.'; end if;
  insert into gift_sends (from_user, to_user, match_id, gift, note)
  values (p_user, case when m.user_a = p_user then m.user_b else m.user_a end, m.id, p_gift, left(nullif(btrim(p_note), ''), 140))
  returning id into v;
  return jsonb_build_object('send_id', v, 'name', c.name, 'price_cents', c.price_cents);
end $$;

-- ---------------------------------------------------------------------
-- Message checks: voice, gifts (only through deliver_gift), the day-4 text pause, contact filter
-- ---------------------------------------------------------------------
create or replace function public.tg_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m       matches;
  kinds   text[];
  blocked text[];
begin
  select * into m from matches where id = new.match_id;
  if m.id is null or new.sender_id not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then raise exception 'This match has ended'; end if;
  if (select status from profiles where id = new.sender_id) <> 'active' then raise exception 'Account not active'; end if;
  new.read_at := null;

  if new.kind = 'gift' then
    if coalesce(current_setting('based.gift', true), '') <> 'on' then raise exception 'Gifts are sent from the gift button.'; end if;
    return new;
  end if;
  new.gift := null;

  if new.kind = 'voice' then
    if new.audio_path is null or new.audio_path not like m.id::text || '/' || new.sender_id::text || '/%' then
      raise exception 'That voice note didn''t upload. Try again.';
    end if;
    new.body := 'Voice note';
    return new;
  end if;
  new.audio_path := null;
  new.duration_ms := null;

  if m.voice_swapped_at is null and now() >= m.created_at + interval '4 days' then
    raise exception 'Texting is paused until you both send a voice note.';
  end if;

  kinds := detect_contact(new.body);
  if m.contact_unlocked then
    blocked := array(select unnest(kinds) except select 'phone');
  else
    blocked := kinds;
  end if;

  if cardinality(blocked) > 0 then
    new.status := 'blocked';
    new.block_reason := array_to_string(blocked, ',');
    perform penalize(new.sender_id, 'contact_violation', 0.02, m.id);
    perform notify(new.sender_id, 'message_blocked',
      case when m.contact_unlocked
        then 'Links and social handles can''t be shared. Phone numbers are fine.'
        else 'Numbers unlock once you''ve both sent a voice note.' end);
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Travel mode is premium (free during early access)
-- ---------------------------------------------------------------------
create or replace function public.start_travel(p_lat double precision, p_lng double precision, p_name text, p_days int default 7)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
begin
  if not has_premium(me) then raise exception 'Travel mode comes with Premium.'; end if;
  if p_lat is null or p_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 then raise exception 'Pick a place.'; end if;
  select * into p from profiles where id = me;
  perform set_config('based.travel', 'on', true);
  update profiles
     set home_lat = case when p.travel_until > now() then p.home_lat else p.lat end,
         home_lng = case when p.travel_until > now() then p.home_lng else p.lng end,
         travel_lat = p_lat, travel_lng = p_lng, travel_name = left(coalesce(p_name, 'Away'), 80),
         travel_until = now() + make_interval(days => least(greatest(coalesce(p_days, 7), 1), 30)),
         lat = p_lat, lng = p_lng
   where id = me;
  perform set_config('based.travel', '', true);
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.has_premium(uuid)', 'public.mark_match_read(uuid)', 'public.swap_voice_question()',
    'public.send_gift(uuid,text,text)', 'public.my_membership()', 'public.undo_last_pass()',
    'public.inner_mark(uuid)', 'public.draw_voice_question()', 'public.start_travel(double precision,double precision,text,int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.deliver_gift(uuid,int)', 'public.prepare_gift(uuid,uuid,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
