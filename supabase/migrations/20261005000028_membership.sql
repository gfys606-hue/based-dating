-- Membership: two paid tiers, and partner venues as the only "ads".
--
--   Free   25 Ouch picks a day.
--   Plus   $4.99/mo  · 50 Ouch picks a day · undo a pass.
--   Inner  $14.99/mo · everything in Plus · travel mode · +2 personal invites a month
--                      · an Inner mark that only other Inner members can see.
--
-- Payments come in through the stripe-webhook function (service role), or an admin comp.
-- Partner venues can be featured: they sort first in Spots and in "Suggest a place to meet".

-- ---------- memberships ----------
create table if not exists public.memberships (
  user_id             uuid primary key references public.profiles(id) on delete cascade,
  tier                text not null check (tier in ('plus','inner')),
  source              text not null default 'stripe' check (source in ('stripe','play','admin')),
  status              text not null default 'active' check (status in ('active','past_due','canceled')),
  current_period_end  timestamptz,
  cancel_at_period_end boolean not null default false,
  stripe_customer     text,
  stripe_subscription text,
  updated_at          timestamptz not null default now()
);
alter table public.memberships enable row level security;   -- functions only
create index if not exists memberships_stripe_customer on public.memberships (stripe_customer);

-- travel mode columns (used below)
alter table public.profiles add column if not exists travel_lat   double precision;
alter table public.profiles add column if not exists travel_lng   double precision;
alter table public.profiles add column if not exists travel_name  text;
alter table public.profiles add column if not exists travel_until timestamptz;
alter table public.profiles add column if not exists home_lat     double precision;
alter table public.profiles add column if not exists home_lng     double precision;
alter table public.profiles add column if not exists last_inner_bonus timestamptz;

create or replace function public.membership_tier(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((
    select m.tier from memberships m
     where m.user_id = p_user
       and m.status in ('active','past_due')
       and (m.current_period_end is null or m.current_period_end > now())), 'free');
$$;

create or replace function public.daily_pick_cap(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  select case when membership_tier(p_user) = 'free' then 25 else 50 end;
$$;

create or replace function public.my_membership()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tier', membership_tier(auth.uid()),
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

-- Called by the stripe-webhook function with the service role. Never by members.
create or replace function public.apply_subscription(
  p_user uuid, p_tier text, p_status text, p_period_end timestamptz,
  p_cancel_at_end boolean, p_customer text, p_subscription text)
returns void language plpgsql security definer set search_path = public as $$
declare
  was text := membership_tier(p_user);
begin
  if p_tier not in ('plus','inner') then raise exception 'Unknown tier'; end if;
  insert into memberships (user_id, tier, source, status, current_period_end, cancel_at_period_end, stripe_customer, stripe_subscription, updated_at)
  values (p_user, p_tier, 'stripe', p_status, p_period_end, coalesce(p_cancel_at_end, false), p_customer, p_subscription, now())
  on conflict (user_id) do update
     set tier = excluded.tier, source = 'stripe', status = excluded.status,
         current_period_end = excluded.current_period_end, cancel_at_period_end = excluded.cancel_at_period_end,
         stripe_customer = coalesce(excluded.stripe_customer, memberships.stripe_customer),
         stripe_subscription = coalesce(excluded.stripe_subscription, memberships.stripe_subscription),
         updated_at = now();
  perform after_tier_change(p_user, was);
end $$;

-- Stripe customer for a member (so the portal link works), stored by the billing function.
create or replace function public.set_stripe_customer(p_user uuid, p_customer text)
returns void language sql security definer set search_path = public as $$
  update memberships set stripe_customer = p_customer, updated_at = now() where user_id = p_user;
$$;

create or replace function public.stripe_customer_for(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select stripe_customer from memberships where user_id = p_user;
$$;

create or replace function public.user_for_stripe_customer(p_customer text)
returns uuid language sql stable security definer set search_path = public as $$
  select user_id from memberships where stripe_customer = p_customer limit 1;
$$;

-- Admin comps (testing, partners, friends of the house)
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
    if p_tier not in ('plus','inner') then raise exception 'Unknown tier'; end if;
    insert into memberships (user_id, tier, source, status, current_period_end)
    values (p_user, p_tier, 'admin', 'active', now() + make_interval(days => greatest(1, coalesce(p_days, 30))))
    on conflict (user_id) do update
       set tier = excluded.tier, source = 'admin', status = 'active',
           current_period_end = excluded.current_period_end, cancel_at_period_end = false, updated_at = now();
  end if;
  perform after_tier_change(p_user, was);
end $$;

create or replace function public.admin_members(p_query text default null)
returns table (user_id uuid, name text, email text, tier text, source text, until timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  perform require_admin();
  return query
  select p.id, p.display_name, u.email::text, membership_tier(p.id), m.source, m.current_period_end
  from profiles p
  left join auth.users u on u.id = p.id
  left join memberships m on m.user_id = p.id
  where (p_query is null and m.user_id is not null)
     or (p_query is not null and (p.display_name ilike '%' || p_query || '%' or u.email ilike '%' || p_query || '%'))
  order by m.updated_at desc nulls last, p.display_name
  limit 50;
end $$;

-- ---------- Inner: +2 personal invites a month ----------
alter table public.profiles add column if not exists last_inner_bonus timestamptz;

create or replace function public.grant_inner_bonus(p_user uuid)
returns void language sql security definer set search_path = public as $$
  update profiles
     set invites_left = invites_left + 2, last_inner_bonus = now()
   where id = p_user and status = 'active'
     and coalesce(invites_frozen_until, '-infinity') < now()
     and (last_inner_bonus is null or last_inner_bonus < now() - interval '30 days');
$$;

create or replace function public.refill_inner_invites()
returns void language sql security definer set search_path = public as $$
  select grant_inner_bonus(m.user_id) from memberships m where membership_tier(m.user_id) = 'inner';
$$;

-- What changes when someone's tier changes
create or replace function public.after_tier_change(p_user uuid, p_was text)
returns void language plpgsql security definer set search_path = public as $$
declare
  now_tier text := membership_tier(p_user);
begin
  if now_tier = 'inner' and p_was <> 'inner' then
    perform grant_inner_bonus(p_user);
    perform notify(p_user, 'membership', 'Welcome to Inner. Two extra invites are waiting for you.');
  elsif now_tier = 'plus' and p_was = 'free' then
    perform notify(p_user, 'membership', 'Plus is on: 50 Ouch picks a day, and undo.');
  end if;
  if now_tier <> 'inner' then perform end_travel_for(p_user); end if;
end $$;

-- ---------- Plus: undo the last pass ----------
create or replace function public.undo_last_pass()
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_to uuid;
begin
  if membership_tier(me) = 'free' then raise exception 'Undo comes with Plus.'; end if;
  select to_user into v_to from passes
   where from_user = me and created_at > now() - interval '1 day'
   order by created_at desc limit 1;
  if v_to is null then return null; end if;
  delete from passes where from_user = me and to_user = v_to;
  return v_to;
end $$;

-- ---------- Inner: travel mode ----------
-- While travelling, your location for matching, the feed and Spots is the place you picked.
-- Your phone's real location is kept aside and comes back when the trip ends.
alter table public.profiles add column if not exists travel_lat   double precision;
alter table public.profiles add column if not exists travel_lng   double precision;
alter table public.profiles add column if not exists travel_name  text;
alter table public.profiles add column if not exists travel_until timestamptz;
alter table public.profiles add column if not exists home_lat     double precision;
alter table public.profiles add column if not exists home_lng     double precision;

create or replace function public.tg_travel_guard()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('based.travel', true), '') <> 'on' then
    -- members can't write these directly
    new.travel_lat := old.travel_lat;  new.travel_lng := old.travel_lng;
    new.travel_name := old.travel_name; new.travel_until := old.travel_until;
    new.home_lat := old.home_lat;      new.home_lng := old.home_lng;
    -- a phone location update while travelling goes to "home", not to the live location
    if old.travel_until > now() and (new.lat is distinct from old.lat or new.lng is distinct from old.lng) then
      new.home_lat := new.lat; new.home_lng := new.lng;
      new.lat := old.lat;      new.lng := old.lng;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profile_travel_guard on public.profiles;
create trigger profile_travel_guard before update on public.profiles
  for each row execute function public.tg_travel_guard();

create or replace function public.start_travel(p_lat double precision, p_lng double precision, p_name text, p_days int default 7)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
begin
  if membership_tier(me) <> 'inner' then raise exception 'Travel mode comes with Inner.'; end if;
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

create or replace function public.end_travel_for(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('based.travel', 'on', true);
  update profiles
     set lat = coalesce(home_lat, lat), lng = coalesce(home_lng, lng),
         travel_lat = null, travel_lng = null, travel_name = null, travel_until = null,
         home_lat = null, home_lng = null
   where id = p_user and (travel_until is not null or travel_lat is not null);
  perform set_config('based.travel', '', true);
end $$;

create or replace function public.end_travel()
returns void language sql security definer set search_path = public as $$
  select end_travel_for(auth.uid());
$$;

create or replace function public.expire_travel()
returns void language sql security definer set search_path = public as $$
  select end_travel_for(id) from profiles where travel_until is not null and travel_until <= now();
$$;

-- ---------- Inner: the Inner mark (only Inner members see each other's) ----------
create or replace function public.inner_mark(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select membership_tier(auth.uid()) = 'inner' and membership_tier(p_user) = 'inner' and p_user <> auth.uid();
$$;

-- ---------- Partner venues: featured placement ----------
alter table public.venues add column if not exists featured_until timestamptz;

create or replace function public.admin_set_featured(p_venue uuid, p_days int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update venues set featured_until = case when coalesce(p_days, 0) <= 0 then null
                                          else now() + make_interval(days => p_days) end
   where id = p_venue;
end $$;

drop function if exists public.get_partner_venues(int);
create or replace function public.get_partner_venues(p_km int default 15)
returns table (venue_id uuid, place_id uuid, name text, address text, lat double precision, lng double precision,
               distance_km double precision, friends_here int, featured boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select vn.id, pl.id, pl.name, pl.address, pl.lat, pl.lng,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1)::double precision end,
         (select count(*)::int from checkins c where c.place_id = pl.id and c.until > now() and can_see_checkin(c.user_id, me)),
         coalesce(vn.featured_until > now(), false)
  from venues vn join places pl on pl.id = vn.place_id
  where not is_barred(me, pl.id)
    and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= coalesce(p_km, 15))
  order by coalesce(vn.featured_until > now(), false) desc,
           case when v.lat is null then 0 else haversine_km(v.lat, v.lng, pl.lat, pl.lng) end
  limit 20;
end $$;

drop function if exists public.admin_venues();
create or replace function public.admin_venues()
returns table (venue_id uuid, name text, staff text, pass_allowance int, passes_made int, joined int, featured_until timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select vn.id, pl.name,
         (select string_agg(p.display_name || ' (' || s.role || ')', ', ') from venue_staff s join profiles p on p.id = s.user_id where s.venue_id = vn.id),
         vn.pass_allowance,
         (select count(*)::int from invite_codes c where c.venue_id = vn.id),
         (select count(*)::int from invite_redemptions r join invite_codes c on c.code = r.code where c.venue_id = vn.id),
         vn.featured_until
  from venues vn join places pl on pl.id = vn.place_id
  order by pl.name;
end $$;

-- ---------- Plus: bigger daily batch (get_match_batch and like_user use daily_pick_cap) ----------
create or replace function public.get_match_batch(p_limit int default 10)
returns table (
  user_id uuid, display_name text, age int, distance_km int,
  shared_topics text[], photo_paths text[]
)
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  v        profiles;
  v_tier   text;
  v_des    real;
  v_acted  int;
  v_cap    int := daily_pick_cap(auth.uid());
begin
  select * into v from profiles where id = me;
  if v.id is null or v.status <> 'active' or v.lat is null or not v.dating_on then return; end if;

  v_tier := effective_tier(me);
  if v_tier = 'invisible' then return; end if;

  select count(*) into v_acted from (
    select 1 from likes  where from_user = me and created_at > now() - interval '1 day'
    union all
    select 1 from passes where from_user = me and created_at > now() - interval '1 day') x;
  if v_acted >= v_cap then return; end if;

  select s.desirability into v_des from user_scores s where s.user_id = me;

  create temp table if not exists _batch (
    user_id uuid, display_name text, age int, distance_km int,
    shared_topics text[], photo_paths text[], rn bigint) on commit drop;
  truncate _batch;

  insert into _batch
  with cand as (
    select c.id, c.display_name, c.birthdate,
           haversine_km(v.lat, v.lng, c.lat, c.lng) as km,
           effective_tier(c.id) as tier,
           abs(coalesce(s.desirability, 0.5) - coalesce(v_des, 0.5)) as gap,
           match_features(me, c.id) as f
    from profiles c
    left join user_scores s on s.user_id = c.id
    where c.id <> me
      and c.status = 'active'
      and c.dating_on
      and c.lat is not null
      and c.gender = any (v.seeking)
      and v.gender = any (c.seeking)
      and not exists (select 1 from likes  l where l.from_user = me and l.to_user = c.id)
      and not exists (select 1 from passes p where p.from_user = me and p.to_user = c.id)
      and not exists (select 1 from matches m where m.user_a = least(me, c.id) and m.user_b = greatest(me, c.id))
      and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = c.id) or (b.blocker = c.id and b.blocked = me))
  ),
  scored as (
    select cand.*,
           distance_block(km) as blk,
           (select coalesce(array_agg(t.name order by t.name), '{}')
              from user_topics a join user_topics b on a.topic_id = b.topic_id and b.user_id = cand.id
              join topics t on t.id = a.topic_id
             where a.user_id = me) as shared
    from cand
    where distance_block(km) is not null
      and tier <> 'invisible'
      and ((v_tier = 'low' and tier in ('low','slipping'))
        or (v_tier <> 'low' and tier in ('healthy','slipping')))
  ),
  w as (select * from my_match_weights(me)),
  ranked as (
    select scored.*,
           row_number() over (order by
             blk,
             case tier when 'healthy' then 0 when 'slipping' then 1 else 2 end,
             -- learned per person: how much they care about interests, temperament, schedule, distance, style.
             -- Inside 10 km interests count double; further out, closeness counts double.
             -( (case when blk = 10 then 2 else 1 end) * w.wi * (f ->> 'interests')::real
              + w.wt * (f ->> 'temperament')::real
              + w.ws * (f ->> 'schedule')::real
              + (case when blk = 10 then 1 else 2 end) * w.wd * (f ->> 'distance')::real
              + w.wy * (f ->> 'style')::real
              - 1.5 * gap)) as rn
    from scored cross join w
  )
  select r.id, r.display_name,
         extract(year from age(r.birthdate))::int,
         greatest(1, round(r.km))::int,
         r.shared,
         (select coalesce(array_agg(ph.storage_path order by ph.position), '{}')
            from photos ph where ph.user_id = r.id and ph.review_status = 'approved'),
         r.rn
  from ranked r
  where r.rn <= least(p_limit, v_cap - v_acted);

  insert into impressions (viewer, shown)
  select me, b.user_id from _batch b
  on conflict do nothing;

  return query
    select b.user_id, b.display_name, b.age, b.distance_km, b.shared_topics, b.photo_paths
    from _batch b order by b.rn;
end $$;

create or replace function public.like_user(p_target uuid)
returns uuid   -- match id if it's mutual, else null
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_match uuid;
begin
  if (select status from profiles where id = me) <> 'active' then raise exception 'Account not active'; end if;
  if effective_tier(me) = 'invisible' then raise exception 'Account not active'; end if;
  if not coalesce((select dating_on from profiles where id = me), false) then raise exception 'Turn on dating first.'; end if;
  if not coalesce((select dating_on from profiles where id = p_target), false) then raise exception 'They aren''t dating right now.'; end if;
  if (select count(*) from likes where from_user = me and created_at > now() - interval '1 day')
   + (select count(*) from passes where from_user = me and created_at > now() - interval '1 day') >= daily_pick_cap(me) then
    raise exception 'Daily limit reached. New matches tomorrow.';
  end if;

  insert into likes (from_user, to_user) values (me, p_target) on conflict do nothing;

  if exists (select 1 from likes where from_user = p_target and to_user = me)
     and (select status from profiles where id = p_target) = 'active' then
    insert into matches (user_a, user_b, icebreaker)
    values (least(me, p_target), greatest(me, p_target), make_icebreaker(me, p_target))
    on conflict (user_a, user_b) do nothing
    returning id into v_match;

    if v_match is not null then
      perform notify(p_target, 'match', 'New match. You have 3 days to get a call in.');
      perform notify(me,       'match', 'New match. You have 3 days to get a call in.');
    end if;
  end if;
  return v_match;
end $$;

-- ---------- schedules ----------
select cron.schedule('expire-travel', '*/15 * * * *', $$select public.expire_travel()$$);
select cron.schedule('inner-invites', '23 4 * * *', $$select public.refill_inner_invites()$$);

-- ---------- permissions ----------
do $$
declare f text;
begin
  foreach f in array array[
    'public.my_membership()', 'public.undo_last_pass()', 'public.start_travel(double precision,double precision,text,int)',
    'public.end_travel()', 'public.inner_mark(uuid)', 'public.get_partner_venues(int)', 'public.admin_venues()',
    'public.admin_set_featured(uuid,int)', 'public.admin_grant_membership(uuid,text,int)', 'public.admin_members(text)',
    'public.get_match_batch(int)', 'public.like_user(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.membership_tier(uuid)', 'public.daily_pick_cap(uuid)',
    'public.apply_subscription(uuid,text,text,timestamptz,boolean,text,text)', 'public.set_stripe_customer(uuid,text)',
    'public.stripe_customer_for(uuid)', 'public.user_for_stripe_customer(text)', 'public.grant_inner_bonus(uuid)',
    'public.refill_inner_invites()', 'public.after_tier_change(uuid,text)', 'public.end_travel_for(uuid)',
    'public.expire_travel()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
