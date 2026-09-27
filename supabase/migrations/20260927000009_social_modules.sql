-- =====================================================================
-- Based Social modules beyond dating: Circles, Search, Events, Market.
-- Testers only for now: every table and function checks profiles.is_tester.
-- Turn someone into a tester: Table Editor → profiles → is_tester = true.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tester flag (clients can't set it themselves)
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists is_tester boolean not null default false,
  add column if not exists use_activity_for_matching boolean not null default false; -- opt-in: searches feed matching

create or replace function public.tg_profile_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    new.status          := old.status;
    new.pause_reason    := old.pause_reason;
    new.selfie_verified := old.selfie_verified;
    new.ad_free         := old.ad_free;
    new.created_at      := old.created_at;
    new.is_tester       := old.is_tester;
  end if;
  return new;
end $$;

create or replace function public.is_tester(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_tester from profiles where id = p_user), false);
$$;

create or replace function public.require_tester()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or not is_tester(me) then raise exception 'This part of Based is still in testing.'; end if;
  return me;
end $$;

-- Overlap between two availability maps: {"mon":["evening"],"sat":["morning"]}
create or replace function public.availability_overlap(a jsonb, b jsonb)
returns int language sql immutable as $$
  select count(*)::int from (
    select d.key, s.value from jsonb_each(coalesce(a, '{}')) d, jsonb_array_elements_text(d.value) s
    intersect
    select d.key, s.value from jsonb_each(coalesce(b, '{}')) d, jsonb_array_elements_text(d.value) s
  ) x;
$$;

-- =====================================================================
-- CIRCLES: small groups (max 8) of people who fit together
-- =====================================================================
create table public.circles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 60),
  topic_id    int references public.topics(id),
  lat         double precision,
  lng         double precision,
  max_size    int not null default 8 check (max_size between 3 and 20),
  created_at  timestamptz not null default now()
);

create table public.circle_members (
  circle_id  uuid references public.circles(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (circle_id, user_id)
);
create index on public.circle_members (user_id);

create table public.circle_messages (
  id          uuid primary key default gen_random_uuid(),
  circle_id   uuid not null references public.circles(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index on public.circle_messages (circle_id, created_at);

create or replace function public.is_circle_member(p_circle uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from circle_members where circle_id = p_circle and user_id = p_user);
$$;

-- My circles with what the list needs
create or replace function public.get_my_circles()
returns table (circle_id uuid, name text, topic text, member_count int,
               last_message text, last_message_at timestamptz, joined_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select c.id, c.name, t.name,
         (select count(*)::int from circle_members x where x.circle_id = c.id),
         lm.body, lm.created_at, cm.joined_at
  from circle_members cm
  join circles c on c.id = cm.circle_id
  left join topics t on t.id = c.topic_id
  left join lateral (select body, created_at from circle_messages m
                     where m.circle_id = c.id order by created_at desc limit 1) lm on true
  where cm.user_id = me
  order by coalesce(lm.created_at, cm.joined_at) desc;
end $$;

-- Members of a circle (only visible to members). No location, no scores.
create or replace function public.get_circle_members(p_circle uuid)
returns table (user_id uuid, name text, photo text, shared_interests int)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if not is_circle_member(p_circle, me) then raise exception 'Not in this circle'; end if;
  return query
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         (select count(*)::int from user_topics a join user_topics b on a.topic_id = b.topic_id
           where a.user_id = me and b.user_id = p.id)
  from circle_members cm join profiles p on p.id = cm.user_id
  where cm.circle_id = p_circle
  order by cm.joined_at;
end $$;

-- Place me in the circle I fit best (or start one). Scores nearby open circles by
-- shared interests with the members, overlapping free time, and distance.
create or replace function public.find_my_circle()
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  best uuid;
  v_topic int;
  v_name text;
begin
  select * into v from profiles where id = me;

  select c.id into best
  from circles c
  where not exists (select 1 from circle_members x where x.circle_id = c.id and x.user_id = me)
    and (select count(*) from circle_members x where x.circle_id = c.id) < c.max_size
    and (c.lat is null or v.lat is null or haversine_km(v.lat, v.lng, c.lat, c.lng) <= 50)
    and not exists (select 1 from circle_members x join blocks b
                      on (b.blocker = me and b.blocked = x.user_id) or (b.blocker = x.user_id and b.blocked = me)
                    where x.circle_id = c.id)
  order by
    ( (select count(*) from circle_members x join user_topics a on a.user_id = x.user_id
        join user_topics mine on mine.topic_id = a.topic_id and mine.user_id = me
       where x.circle_id = c.id)::float8
         / greatest(1, (select count(*) from circle_members x where x.circle_id = c.id))
    + case when exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = c.topic_id) then 2 else 0 end
    + (select coalesce(avg(availability_overlap(v.availability, p.availability)), 0)
         from circle_members x join profiles p on p.id = x.user_id where x.circle_id = c.id) * 0.5
    - case when c.lat is null or v.lat is null then 0 else haversine_km(v.lat, v.lng, c.lat, c.lng) / 25.0 end
    ) desc
  limit 1;

  -- Only join an existing circle if it shares at least one of my interests
  if best is not null and not exists (
      select 1 from circles c join user_topics ut on ut.topic_id = c.topic_id and ut.user_id = me where c.id = best)
     and not exists (
      select 1 from circle_members x join user_topics a on a.user_id = x.user_id
        join user_topics mine on mine.topic_id = a.topic_id and mine.user_id = me where x.circle_id = best) then
    best := null;
  end if;

  if best is null then
    -- Start a circle around my interest that's most common nearby
    select ut.topic_id into v_topic
    from user_topics ut
    left join user_topics o on o.topic_id = ut.topic_id and o.user_id <> me
    left join profiles op on op.id = o.user_id
    where ut.user_id = me
      and (op.id is null or op.lat is null or v.lat is null or haversine_km(v.lat, v.lng, op.lat, op.lng) <= 50)
    group by ut.topic_id
    order by count(o.user_id) desc
    limit 1;

    select name into v_name from topics where id = v_topic;
    insert into circles (name, topic_id, lat, lng)
    values (coalesce(v_name, 'New') || ' circle', v_topic, v.lat, v.lng)
    returning id into best;
  end if;

  insert into circle_members (circle_id, user_id) values (best, me) on conflict do nothing;
  return best;
end $$;

create or replace function public.leave_circle(p_circle uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  delete from circle_members where circle_id = p_circle and user_id = me;
  delete from circles c where c.id = p_circle and not exists (select 1 from circle_members x where x.circle_id = c.id);
end $$;

-- =====================================================================
-- EVENTS / SCHEDULER
-- =====================================================================
create table public.events (
  id          uuid primary key default gen_random_uuid(),
  creator_id  uuid not null references public.profiles(id) on delete cascade,
  circle_id   uuid references public.circles(id) on delete cascade, -- null = open to everyone nearby
  title       text not null check (char_length(title) between 1 and 80),
  details     text check (char_length(details) <= 1000),
  topic_id    int references public.topics(id),
  place_name  text check (char_length(place_name) <= 120),
  starts_at   timestamptz not null,
  lat         double precision,
  lng         double precision,
  capacity    int check (capacity is null or capacity between 2 and 500),
  status      text not null default 'active' check (status in ('active','cancelled')),
  created_at  timestamptz not null default now()
);
create index on public.events (starts_at);

create table public.event_rsvps (
  event_id   uuid references public.events(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  status     text not null check (status in ('going','maybe')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create or replace function public.get_events(p_km int default 50, p_circle uuid default null)
returns table (event_id uuid, title text, details text, topic text, place_name text,
               starts_at timestamptz, distance_km int, going int, capacity int,
               my_rsvp text, mine boolean, circle_id uuid, circle_name text, creator_name text)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select e.id, e.title, e.details, t.name, e.place_name, e.starts_at,
         case when e.lat is null or v.lat is null then null
              else greatest(1, round(haversine_km(v.lat, v.lng, e.lat, e.lng)))::int end,
         (select count(*)::int from event_rsvps r where r.event_id = e.id and r.status = 'going'),
         e.capacity,
         (select r.status from event_rsvps r where r.event_id = e.id and r.user_id = me),
         e.creator_id = me, e.circle_id, c.name, cr.display_name
  from events e
  left join topics t on t.id = e.topic_id
  left join circles c on c.id = e.circle_id
  join profiles cr on cr.id = e.creator_id
  where e.status = 'active'
    and e.starts_at > now() - interval '2 hours'
    and (p_circle is null or e.circle_id = p_circle)
    and (e.circle_id is null or is_circle_member(e.circle_id, me))
    and (e.circle_id is not null or e.lat is null or v.lat is null
         or haversine_km(v.lat, v.lng, e.lat, e.lng) <= p_km)
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = e.creator_id)
                                            or (b.blocker = e.creator_id and b.blocked = me))
  order by
    (exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = e.topic_id)) desc,
    e.starts_at
  limit 100;
end $$;

create or replace function public.create_event(
  p_title text, p_starts_at timestamptz, p_details text default null, p_place text default null,
  p_topic int default null, p_circle uuid default null, p_capacity int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_id uuid;
begin
  if p_starts_at < now() then raise exception 'Pick a time in the future'; end if;
  if p_circle is not null and not is_circle_member(p_circle, me) then raise exception 'Not in this circle'; end if;
  select * into v from profiles where id = me;
  insert into events (creator_id, circle_id, title, details, topic_id, place_name, starts_at, lat, lng, capacity)
  values (me, p_circle, p_title, p_details, p_topic, p_place, p_starts_at, v.lat, v.lng, p_capacity)
  returning id into v_id;
  insert into event_rsvps (event_id, user_id, status) values (v_id, me, 'going');
  return v_id;
end $$;

create or replace function public.rsvp_event(p_event uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  e events;
begin
  select * into e from events where id = p_event and status = 'active';
  if e.id is null then raise exception 'Event not found'; end if;
  if e.circle_id is not null and not is_circle_member(e.circle_id, me) then raise exception 'Not in this circle'; end if;
  if p_status is null or p_status = 'none' then
    delete from event_rsvps where event_id = p_event and user_id = me;
    return;
  end if;
  if p_status = 'going' and e.capacity is not null
     and (select count(*) from event_rsvps where event_id = p_event and status = 'going' and user_id <> me) >= e.capacity then
    raise exception 'This event is full';
  end if;
  insert into event_rsvps (event_id, user_id, status) values (p_event, me, p_status)
  on conflict (event_id, user_id) do update set status = excluded.status;
end $$;

create or replace function public.cancel_event(p_event uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  update events set status = 'cancelled' where id = p_event and creator_id = me;
end $$;

-- =====================================================================
-- MARKET: local buy & sell (messaging only; no payments yet)
-- =====================================================================
create table public.listings (
  id           uuid primary key default gen_random_uuid(),
  seller_id    uuid not null references public.profiles(id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 80),
  description  text check (char_length(description) <= 2000),
  price_cents  int not null check (price_cents between 0 and 100000000),
  category     text not null check (category in ('vehicles','tools','outdoors','home','electronics','clothing','sports','other')),
  condition    text not null default 'used' check (condition in ('new','like_new','used','for_parts')),
  photo_path   text,
  lat          double precision,
  lng          double precision,
  status       text not null default 'active' check (status in ('active','sold','removed')),
  created_at   timestamptz not null default now()
);
create index on public.listings (created_at desc);

create table public.listing_threads (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references public.listings(id) on delete cascade,
  buyer_id    uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (listing_id, buyer_id)
);

create table public.listing_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.listing_threads(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index on public.listing_messages (thread_id, created_at);

create or replace function public.in_listing_thread(p_thread uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from listing_threads t join listings l on l.id = t.listing_id
                 where t.id = p_thread and p_user in (t.buyer_id, l.seller_id));
$$;

create or replace function public.get_listings(p_query text default null, p_category text default null,
                                               p_km int default 50, p_mine boolean default false)
returns table (listing_id uuid, title text, description text, price_cents int, category text, condition text,
               photo_path text, distance_km int, created_at timestamptz, status text, mine boolean,
               seller_id uuid, seller_name text)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select l.id, l.title, l.description, l.price_cents, l.category, l.condition, l.photo_path,
         case when l.lat is null or v.lat is null then null
              else greatest(1, round(haversine_km(v.lat, v.lng, l.lat, l.lng)))::int end,
         l.created_at, l.status, l.seller_id = me, l.seller_id, s.display_name
  from listings l join profiles s on s.id = l.seller_id
  where (case when p_mine then l.seller_id = me and l.status <> 'removed'
              else l.status = 'active'
                   and s.status = 'active'
                   and (l.lat is null or v.lat is null or haversine_km(v.lat, v.lng, l.lat, l.lng) <= p_km) end)
    and (p_category is null or l.category = p_category)
    and (p_query is null or l.title ilike '%' || p_query || '%' or l.description ilike '%' || p_query || '%')
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = l.seller_id)
                                            or (b.blocker = l.seller_id and b.blocked = me))
  order by l.created_at desc
  limit 100;
end $$;

create or replace function public.create_listing(p_title text, p_price_cents int, p_category text,
  p_condition text default 'used', p_description text default null, p_photo text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_id uuid;
begin
  if p_photo is not null and split_part(p_photo, '/', 1) <> me::text then raise exception 'Bad photo'; end if;
  select * into v from profiles where id = me;
  insert into listings (seller_id, title, description, price_cents, category, condition, photo_path, lat, lng)
  values (me, p_title, p_description, p_price_cents, p_category, p_condition, p_photo, v.lat, v.lng)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_listing_status(p_listing uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if p_status not in ('active','sold','removed') then raise exception 'Bad status'; end if;
  update listings set status = p_status where id = p_listing and seller_id = me;
end $$;

-- Open (or reuse) my conversation with the seller about a listing
create or replace function public.message_seller(p_listing uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  l listings;
  v_id uuid;
begin
  select * into l from listings where id = p_listing and status = 'active';
  if l.id is null then raise exception 'This listing is no longer available'; end if;
  if l.seller_id = me then raise exception 'This is your listing'; end if;
  insert into listing_threads (listing_id, buyer_id) values (p_listing, me)
  on conflict (listing_id, buyer_id) do update set listing_id = excluded.listing_id
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_my_listing_threads()
returns table (thread_id uuid, listing_id uuid, listing_title text, photo_path text, price_cents int,
               other_name text, i_am_seller boolean, last_message text, last_message_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select t.id, l.id, l.title, l.photo_path, l.price_cents,
         case when l.seller_id = me then b.display_name else s.display_name end,
         l.seller_id = me, lm.body, lm.created_at
  from listing_threads t
  join listings l on l.id = t.listing_id
  join profiles b on b.id = t.buyer_id
  join profiles s on s.id = l.seller_id
  left join lateral (select body, created_at from listing_messages m
                     where m.thread_id = t.id order by created_at desc limit 1) lm on true
  where me in (t.buyer_id, l.seller_id)
  order by coalesce(lm.created_at, t.created_at) desc;
end $$;

-- =====================================================================
-- SEARCH: one box for people, posts, circles, events and listings
-- =====================================================================
create table public.search_history (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  query       text not null,
  created_at  timestamptz not null default now()
);
create index on public.search_history (user_id, created_at desc);

create or replace function public.search_all(p_query text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  q text := btrim(coalesce(p_query, ''));
  pat text;
begin
  if char_length(q) < 2 then return '{}'::jsonb; end if;
  q := left(q, 100);
  pat := '%' || replace(replace(q, '%', ''), '_', '') || '%';
  select * into v from profiles where id = me;

  -- Only kept when the user has opted in; used to improve matching later.
  if v.use_activity_for_matching then
    insert into search_history (user_id, query) values (me, q);
  end if;

  return jsonb_build_object(
    'topics', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name)), '[]')
               from (select * from topics where name ilike pat order by name limit 8) t),
    'people', (select coalesce(jsonb_agg(x), '[]') from (
                 select p.id, p.display_name as name,
                        (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved') as photo,
                        (select string_agg(t.name, ', ' order by t.name) from user_topics ut join topics t on t.id = ut.topic_id
                          where ut.user_id = p.id and t.name ilike pat) as matched_interests
                 from profiles p
                 where p.status = 'active' and p.id <> me
                   and effective_tier(p.id) <> 'invisible'
                   and (p.display_name ilike pat
                        or exists (select 1 from user_topics ut join topics t on t.id = ut.topic_id
                                   where ut.user_id = p.id and t.name ilike pat))
                   and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id)
                                                           or (b.blocker = p.id and b.blocked = me))
                 order by (case when p.lat is null or v.lat is null then 99999
                                else haversine_km(v.lat, v.lng, p.lat, p.lng) end)
                 limit 20) x),
    'posts', (select coalesce(jsonb_agg(x), '[]') from (
                 select po.id, po.body, t.name as topic, a.display_name as author, po.created_at
                 from posts po join profiles a on a.id = po.author_id and a.status = 'active'
                 join topics t on t.id = po.topic_id
                 where po.status = 'visible' and (po.body ilike pat or t.name ilike pat)
                   and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = po.author_id)
                                                           or (b.blocker = po.author_id and b.blocked = me))
                 order by po.created_at desc limit 20) x),
    'circles', (select coalesce(jsonb_agg(x), '[]') from (
                 select c.id, c.name, t.name as topic,
                        (select count(*) from circle_members m where m.circle_id = c.id)::int as members,
                        is_circle_member(c.id, me) as joined
                 from circles c left join topics t on t.id = c.topic_id
                 where c.name ilike pat or t.name ilike pat
                 order by c.created_at desc limit 10) x),
    'events', (select coalesce(jsonb_agg(x), '[]') from (
                 select e.id, e.title, e.place_name, e.starts_at
                 from events e left join topics t on t.id = e.topic_id
                 where e.status = 'active' and e.starts_at > now() and e.circle_id is null
                   and (e.title ilike pat or e.details ilike pat or t.name ilike pat)
                 order by e.starts_at limit 10) x),
    'listings', (select coalesce(jsonb_agg(x), '[]') from (
                 select l.id, l.title, l.price_cents, l.photo_path
                 from listings l
                 where l.status = 'active' and (l.title ilike pat or l.description ilike pat)
                 order by l.created_at desc limit 10) x)
  );
end $$;

-- Join a specific circle found through search (if there's room)
create or replace function public.join_circle(p_circle uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  c circles;
begin
  select * into c from circles where id = p_circle;
  if c.id is null then raise exception 'Circle not found'; end if;
  if (select count(*) from circle_members where circle_id = p_circle) >= c.max_size then
    raise exception 'This circle is full';
  end if;
  insert into circle_members (circle_id, user_id) values (p_circle, me) on conflict do nothing;
end $$;

-- =====================================================================
-- Row-level security
-- =====================================================================
alter table public.circles          enable row level security;
alter table public.circle_members   enable row level security;
alter table public.circle_messages  enable row level security;
alter table public.events           enable row level security;
alter table public.event_rsvps      enable row level security;
alter table public.listings         enable row level security;
alter table public.listing_threads  enable row level security;
alter table public.listing_messages enable row level security;
alter table public.search_history   enable row level security;

-- Circle chat: members read and post (writes to circles/members/events/listings go through functions)
create policy "circle messages read" on public.circle_messages for select to authenticated
  using (public.is_tester() and public.is_circle_member(circle_id));
create policy "circle messages send" on public.circle_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_tester() and public.is_circle_member(circle_id));

-- Market chat: buyer + seller read and post
create policy "listing messages read" on public.listing_messages for select to authenticated
  using (public.is_tester() and public.in_listing_thread(thread_id));
create policy "listing messages send" on public.listing_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_tester() and public.in_listing_thread(thread_id));

-- Search history: yours to see and clear
create policy "own search history read"   on public.search_history for select to authenticated using (user_id = auth.uid());
create policy "own search history delete" on public.search_history for delete to authenticated using (user_id = auth.uid());

-- Everything else: no direct client access (functions only).

-- Function permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.is_tester(uuid)', 'public.require_tester()', 'public.availability_overlap(jsonb,jsonb)',
    'public.is_circle_member(uuid,uuid)', 'public.in_listing_thread(uuid,uuid)',
    'public.get_my_circles()', 'public.get_circle_members(uuid)', 'public.find_my_circle()',
    'public.leave_circle(uuid)', 'public.join_circle(uuid)',
    'public.get_events(int,uuid)', 'public.create_event(text,timestamptz,text,text,int,uuid,int)',
    'public.rsvp_event(uuid,text)', 'public.cancel_event(uuid)',
    'public.get_listings(text,text,int,boolean)', 'public.create_listing(text,int,text,text,text,text)',
    'public.set_listing_status(uuid,text)', 'public.message_seller(uuid)', 'public.get_my_listing_threads()',
    'public.search_all(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Live chat updates
alter publication supabase_realtime add table public.circle_messages, public.listing_messages;
