-- Travel mode, the full version (priority 4, Oct 19 2026). Premium only (free during early access).
--  * Search any city: browse its partner spots and the members there.
--  * Reach out before the trip: "I'll be there on Oct 30, we're both into X, mind if I join you for drinks?"
--  * Members control it: traveller messages on (default) or off. With it on, a traveller can only reach
--    you if the city they picked is inside your own feed distance.
--  * The city you search is the zone you're messaging from (you're "in" that city for intros).
--  * Accepting an intro makes you friends and puts their message in your friend chat.
-- Safe to re-run.

alter table public.profiles add column if not exists traveler_messages boolean not null default true;

create table if not exists public.travel_intros (
  id         uuid primary key default gen_random_uuid(),
  from_user  uuid not null references public.profiles(id) on delete cascade,
  to_user    uuid not null references public.profiles(id) on delete cascade,
  city       text check (char_length(city) <= 80),
  lat        double precision,
  lng        double precision,
  trip_date  date,
  body       text not null check (char_length(body) between 1 and 500),
  status     text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
alter table public.travel_intros enable row level security;  -- functions only
create index if not exists travel_intros_to on public.travel_intros (to_user, status);
create index if not exists travel_intros_from on public.travel_intros (from_user, created_at);

-- Can a traveller "standing in" (lat, lng) reach this member?
create or replace function public.traveler_can_reach(p_member uuid, p_lat double precision, p_lng double precision)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select p.traveler_messages and p.status = 'active' and p.lat is not null
       and (feed_range_km(p.feed_range) is null
            or haversine_km(p.lat, p.lng, p_lat, p_lng) <= feed_range_km(p.feed_range))
    from profiles p where p.id = p_member), false);
$$;

-- Members in a city (within 30 km of the point) who take traveller messages and are in range
create or replace function public.travel_browse(p_lat double precision, p_lng double precision)
returns table (user_id uuid, name text, age int, photo text, distance_km int, shared text[], pending boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not has_premium(me) then raise exception 'Travel mode comes with Premium.'; end if;
  if p_lat is null or p_lng is null then raise exception 'Pick a city.'; end if;
  return query
  select p.id, p.display_name, extract(year from age(p.birthdate))::int,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         greatest(1, round(haversine_km(p.lat, p.lng, p_lat, p_lng)))::int,
         (select coalesce(array_agg(t.name order by t.name), '{}')
            from user_topics a join user_topics b on b.topic_id = a.topic_id and b.user_id = p.id
            join topics t on t.id = a.topic_id where a.user_id = me),
         exists (select 1 from travel_intros i where i.from_user = me and i.to_user = p.id and i.status = 'pending')
  from profiles p
  where p.id <> me
    and p.lat is not null
    and haversine_km(p.lat, p.lng, p_lat, p_lng) <= 30
    and traveler_can_reach(p.id, p_lat, p_lng)
    and effective_tier(p.id) <> 'invisible'
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
  order by (select count(*) from user_topics a join user_topics b on b.topic_id = a.topic_id and b.user_id = p.id where a.user_id = me) desc,
           haversine_km(p.lat, p.lng, p_lat, p_lng)
  limit 40;
end $$;

-- Partner spots in that city (bars only shown if you're of drinking age where you live)
create or replace function public.travel_venues(p_lat double precision, p_lng double precision)
returns table (venue_id uuid, place_id uuid, name text, address text, distance_km double precision, featured boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not has_premium(me) then raise exception 'Travel mode comes with Premium.'; end if;
  if not bars_ok(me) then return; end if;
  return query
  select vn.id, pl.id, pl.name, pl.address,
         round(haversine_km(p_lat, p_lng, pl.lat, pl.lng)::numeric, 1)::double precision,
         coalesce(vn.featured_until > now(), false)
  from venues vn join places pl on pl.id = vn.place_id
  where haversine_km(p_lat, p_lng, pl.lat, pl.lng) <= 30 and not is_barred(me, pl.id)
  order by coalesce(vn.featured_until > now(), false) desc, haversine_km(p_lat, p_lng, pl.lat, pl.lng)
  limit 30;
end $$;

create or replace function public.send_travel_intro(p_to uuid, p_lat double precision, p_lng double precision,
                                                   p_city text, p_date date, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not has_premium(me) then raise exception 'Travel mode comes with Premium.'; end if;
  if (select status from profiles where id = me) <> 'active' then raise exception 'Account not active'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'Say hi first.'; end if;
  if p_date is not null and p_date < current_date then raise exception 'Pick a date that hasn''t passed.'; end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_to) or (b.blocker = p_to and b.blocked = me))
     or not traveler_can_reach(p_to, p_lat, p_lng) then
    raise exception 'They aren''t taking traveller messages from there.';
  end if;
  if exists (select 1 from travel_intros where from_user = me and to_user = p_to and status = 'pending') then
    raise exception 'You''ve already reached out. Give them a chance to answer.';
  end if;
  if (select count(*) from travel_intros where from_user = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That''s plenty of intros for today. Try again tomorrow.';
  end if;
  if detect_contact(p_body) <> '{}'::text[] then
    raise exception 'Keep contact info out of intros. It unlocks once you''re friends.';
  end if;
  insert into travel_intros (from_user, to_user, city, lat, lng, trip_date, body)
  values (me, p_to, left(p_city, 80), p_lat, p_lng, p_date, left(btrim(p_body), 500));
  perform notify(p_to, 'travel_intro',
    (select display_name from profiles where id = me) || ' is coming to town'
      || coalesce(' on ' || to_char(p_date, 'Mon FMDD'), '') || ' and said hi.');
end $$;

create or replace function public.my_travel_intros()
returns table (id uuid, from_id uuid, name text, age int, photo text, city text, trip_date date, body text,
               shared text[], created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select i.id, p.id, p.display_name, extract(year from age(p.birthdate))::int,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         i.city, i.trip_date, i.body,
         (select coalesce(array_agg(t.name order by t.name), '{}')
            from user_topics a join user_topics b on b.topic_id = a.topic_id and b.user_id = p.id
            join topics t on t.id = a.topic_id where a.user_id = auth.uid()),
         i.created_at
  from travel_intros i join profiles p on p.id = i.from_user and p.status = 'active'
  where i.to_user = auth.uid() and i.status = 'pending'
    and not exists (select 1 from blocks b where (b.blocker = auth.uid() and b.blocked = p.id) or (b.blocker = p.id and b.blocked = auth.uid()))
  order by i.created_at desc;
$$;

-- Yes = friends, and their intro becomes the first message. No = they're never told.
create or replace function public.respond_travel_intro(p_id uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  i travel_intros;
  v_f uuid;
begin
  select * into i from travel_intros where id = p_id and to_user = me and status = 'pending';
  if i.id is null then raise exception 'That intro isn''t waiting anymore.'; end if;
  update travel_intros set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now() where id = i.id;
  if not p_accept then return 'declined'; end if;

  insert into friendships (user_a, user_b, requested_by, status, created_at, responded_at)
  values (least(me, i.from_user), greatest(me, i.from_user), i.from_user, 'accepted', now(), now())
  on conflict (user_a, user_b) do update set status = 'accepted', responded_at = now()
  returning id into v_f;
  insert into friend_messages (friendship_id, sender_id, body) values (v_f, i.from_user, i.body);
  perform notify(i.from_user, 'friend_accepted',
    (select display_name from profiles where id = me) || ' said yes. You''re friends now: say hi.');
  return 'friends';
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.traveler_can_reach(uuid,double precision,double precision)',
    'public.travel_browse(double precision,double precision)', 'public.travel_venues(double precision,double precision)',
    'public.send_travel_intro(uuid,double precision,double precision,text,date,text)',
    'public.my_travel_intros()', 'public.respond_travel_intro(uuid,boolean)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
