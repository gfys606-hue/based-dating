-- Watering holes, exact venue pins, and "Here now".
--  * places: real venues picked from an OpenStreetMap search (exact address + coordinates), shared by everyone.
--  * saved_places: your watering holes (up to 20). Posting a night out = tap a spot, pick a time, send.
--  * events can be pinned to a place, so distance and directions use the venue, not the creator's home.
--  * checkins ("Here now"): opt-in, lasts a set time, only friends / inner circle see it, and quiet mode hides it.

create table if not exists public.places (
  id         uuid primary key default gen_random_uuid(),
  osm_id     text unique,                       -- e.g. "node/123456" (null for hand-made pins)
  name       text not null check (char_length(name) between 1 and 120),
  address    text check (char_length(address) <= 300),
  lat        double precision not null check (lat between -90 and 90),
  lng        double precision not null check (lng between -180 and 180),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.saved_places (
  user_id    uuid references public.profiles(id) on delete cascade,
  place_id   uuid references public.places(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, place_id)
);

alter table public.events add column if not exists place_id uuid references public.places(id) on delete set null;

create table if not exists public.checkins (
  user_id    uuid primary key references public.profiles(id) on delete cascade,  -- one at a time
  place_id   uuid not null references public.places(id) on delete cascade,
  audience   text not null default 'inner' check (audience in ('inner','friends')),
  started_at timestamptz not null default now(),
  until      timestamptz not null
);

alter table public.places       enable row level security;  -- functions only
alter table public.saved_places enable row level security;
alter table public.checkins     enable row level security;

-- ---------------------------------------------------------------------
-- Places
-- ---------------------------------------------------------------------
-- Save a venue the app found on OpenStreetMap (or reuse it if someone already did)
create or replace function public.upsert_place(p_osm_id text, p_name text, p_address text, p_lat double precision, p_lng double precision)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_id uuid;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'That place has no location.';
  end if;
  if p_osm_id is not null then
    select id into v_id from places where osm_id = p_osm_id;
    if v_id is not null then
      update places set name = left(btrim(p_name), 120), address = left(p_address, 300), lat = p_lat, lng = p_lng where id = v_id;
      return v_id;
    end if;
  end if;
  insert into places (osm_id, name, address, lat, lng, created_by)
  values (p_osm_id, left(btrim(p_name), 120), left(p_address, 300), p_lat, p_lng, me)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.save_place(p_place uuid, p_save boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not p_save then
    delete from saved_places where user_id = me and place_id = p_place;
    return;
  end if;
  if (select count(*) from saved_places where user_id = me) >= 20 then
    raise exception 'You can keep up to 20 spots. Remove one first.';
  end if;
  insert into saved_places (user_id, place_id) values (me, p_place) on conflict do nothing;
end $$;

-- My watering holes, closest first, with how many friends are there now
create or replace function public.get_my_places()
returns table (place_id uuid, name text, address text, lat double precision, lng double precision,
               distance_km double precision, friends_here int)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select p.id, p.name, p.address, p.lat, p.lng,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, p.lat, p.lng)::numeric, 1)::double precision end,
         (select count(*)::int from checkins c where c.place_id = p.id and c.until > now() and can_see_checkin(c.user_id, me))
  from saved_places s join places p on p.id = s.place_id
  where s.user_id = me
  order by case when v.lat is null then 0 else haversine_km(v.lat, v.lng, p.lat, p.lng) end, s.created_at;
end $$;

-- ---------------------------------------------------------------------
-- Here now
-- ---------------------------------------------------------------------
create or replace function public.can_see_checkin(p_owner uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_owner = p_viewer or exists (
    select 1 from checkins c
    where c.user_id = p_owner and c.until > now()
      and not is_quiet(p_owner)
      and not exists (select 1 from blocks b where (b.blocker = p_owner and b.blocked = p_viewer)
                                              or (b.blocker = p_viewer and b.blocked = p_owner))
      and case c.audience when 'inner' then in_inner_circle(p_owner, p_viewer)
                          else are_friends(p_owner, p_viewer) end);
$$;

-- p_hours: 1-12. p_notify: let them know with a notification.
create or replace function public.check_in(p_place uuid, p_hours int default 3, p_audience text default 'inner', p_notify boolean default false)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_until timestamptz := now() + make_interval(hours => least(greatest(coalesce(p_hours, 3), 1), 12));
  v_name text;
  v_place text;
  v_to uuid;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if coalesce(p_audience, '') not in ('inner','friends') then raise exception 'Pick who sees it.'; end if;
  select name into v_place from places where id = p_place;
  if v_place is null then raise exception 'Pick a place.'; end if;

  insert into checkins (user_id, place_id, audience, started_at, until)
  values (me, p_place, p_audience, now(), v_until)
  on conflict (user_id) do update set place_id = excluded.place_id, audience = excluded.audience,
                                      started_at = now(), until = excluded.until;

  if p_notify and not is_quiet(me) then
    select display_name into v_name from profiles where id = me;
    for v_to in
      select case when f.user_a = me then f.user_b else f.user_a end
      from friendships f
      where f.status = 'accepted' and me in (f.user_a, f.user_b)
        and (p_audience = 'friends' or (case when f.user_a = me then f.a_inner else f.b_inner end))
    loop
      perform notify(v_to, 'here_now', v_name || ' is at ' || v_place || ' right now.');
    end loop;
  end if;
  return v_until;
end $$;

create or replace function public.check_out()
returns void language sql security definer set search_path = public as $$
  delete from checkins where user_id = auth.uid();
$$;

-- Friends who are out right now (that I'm allowed to see), plus my own check-in
create or replace function public.get_here_now()
returns table (user_id uuid, name text, photo text, is_me boolean, place_id uuid, place_name text, address text,
               lat double precision, lng double precision, started_at timestamptz, until timestamptz,
               audience text, distance_km double precision)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         p.id = me, pl.id, pl.name, pl.address, pl.lat, pl.lng, c.started_at, c.until,
         case when p.id = me then c.audience end,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1)::double precision end
  from checkins c
  join profiles p on p.id = c.user_id and p.status = 'active'
  join places pl on pl.id = c.place_id
  where c.until > now() and can_see_checkin(c.user_id, me)
  order by (p.id = me) desc, c.started_at desc;
end $$;

-- Keep the table small
create or replace function public.sweep_checkins()
returns void language sql security definer set search_path = public as $$
  delete from checkins where until < now() - interval '1 day';
$$;
select cron.schedule('sweep-checkins', '17 * * * *', $$select public.sweep_checkins()$$);

-- ---------------------------------------------------------------------
-- Events pinned to a place
-- ---------------------------------------------------------------------
drop function if exists public.create_event(text, timestamptz, text, text, int, uuid, int, text, uuid[]);
create or replace function public.create_event(
  p_title text, p_starts_at timestamptz, p_details text default null, p_place text default null,
  p_topic int default null, p_circle uuid default null, p_capacity int default null,
  p_audience text default null, p_invitees uuid[] default null, p_place_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  pl places;
  v_id uuid;
  v_aud text := coalesce(p_audience, case when p_circle is null then 'public' else 'circle' end);
  v_to uuid;
  v_msg text;
  v_where text;
begin
  if p_starts_at < now() then raise exception 'Pick a time in the future'; end if;
  if v_aud not in ('public','circle','friends','inner','custom') then raise exception 'Pick who can see it'; end if;
  if v_aud = 'circle' then
    if p_circle is null or not is_circle_member(p_circle, me) then raise exception 'Not in this circle'; end if;
  elsif p_circle is not null then
    raise exception 'Circle plans go to the circle';
  end if;
  if v_aud = 'custom' and coalesce(cardinality(p_invitees), 0) = 0 then raise exception 'Pick at least one person'; end if;
  if coalesce(cardinality(p_invitees), 0) > 50 then raise exception 'Pick up to 50 people'; end if;

  select * into v from profiles where id = me;
  if p_place_id is not null then select * into pl from places where id = p_place_id; end if;
  v_where := coalesce(nullif(btrim(p_place), ''), pl.name);

  insert into events (creator_id, circle_id, title, details, topic_id, place_name, starts_at, lat, lng, capacity, audience, place_id)
  values (me, p_circle, p_title, p_details, p_topic, v_where, p_starts_at,
          coalesce(pl.lat, v.lat), coalesce(pl.lng, v.lng), p_capacity, v_aud, pl.id)
  returning id into v_id;
  insert into event_rsvps (event_id, user_id, status) values (v_id, me, 'going');

  if v_aud = 'custom' then
    insert into event_invitees (event_id, user_id)
    select v_id, u from unnest(p_invitees) u where u <> me and are_friends(me, u)
    on conflict do nothing;
    if not exists (select 1 from event_invitees where event_id = v_id) then
      raise exception 'You can only invite your friends';
    end if;
  end if;

  if v_aud in ('friends','inner','custom') then
    v_msg := v.display_name || ': ' || p_title
             || coalesce(' at ' || nullif(btrim(v_where), ''), '')
             || ' · ' || to_char(p_starts_at at time zone 'America/Edmonton', 'Dy FMHH12:MI AM');
    for v_to in
      select case when f.user_a = me then f.user_b else f.user_a end
      from friendships f
      where f.status = 'accepted' and me in (f.user_a, f.user_b)
        and (v_aud = 'friends'
             or (v_aud = 'inner' and (case when f.user_a = me then f.a_inner else f.b_inner end))
             or (v_aud = 'custom' and exists (select 1 from event_invitees i where i.event_id = v_id
                                              and i.user_id = case when f.user_a = me then f.user_b else f.user_a end)))
    loop
      perform notify(v_to, 'event_invite', v_msg);
    end loop;
  end if;
  return v_id;
end $$;

-- get_events: add the venue pin so the app can show a map and directions
drop function if exists public.get_events(int, uuid);
create or replace function public.get_events(p_km int default 50, p_circle uuid default null)
returns table (event_id uuid, title text, details text, topic text, place_name text,
               starts_at timestamptz, distance_km int, going int, capacity int,
               my_rsvp text, mine boolean, circle_id uuid, circle_name text, creator_name text,
               audience text, invited_count int, place_id uuid, place_address text,
               place_lat double precision, place_lng double precision)
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
         e.creator_id = me, e.circle_id, c.name, cr.display_name,
         e.audience,
         case when e.creator_id = me and e.audience = 'custom'
              then (select count(*)::int from event_invitees i where i.event_id = e.id) end,
         pl.id, pl.address, pl.lat, pl.lng
  from events e
  left join topics t on t.id = e.topic_id
  left join circles c on c.id = e.circle_id
  left join places pl on pl.id = e.place_id
  join profiles cr on cr.id = e.creator_id
  where e.status = 'active'
    and e.starts_at > now() - interval '2 hours'
    and (p_circle is null or e.circle_id = p_circle)
    and can_see_event(e.id, me)
    and (e.audience <> 'public' or e.creator_id = me or e.lat is null or v.lat is null
         or haversine_km(v.lat, v.lng, e.lat, e.lng) <= p_km)
  order by
    (e.audience in ('inner','custom','friends')) desc,
    (exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = e.topic_id)) desc,
    e.starts_at
  limit 100;
end $$;

-- Push title for the new notice kind
create or replace function public.tg_notification_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform send_push(new.user_id,
    case new.kind
      when 'match'            then 'New match'
      when 'call_proposed'    then 'Call request'
      when 'call_accepted'    then 'Call confirmed'
      when 'call_rescheduled' then 'Call moved'
      when 'call_soon'        then 'Call starting soon'
      when 'no_show'          then 'Missed call'
      when 'call_missed'      then 'Missed call'
      when 'match_expired'    then 'Match expired'
      when 'match_ended'      then 'Match ended'
      when 'contact_unlocked' then 'Numbers unlocked'
      when 'paused'           then 'Account paused'
      when 'unpaused'         then 'You''re visible again'
      when 'friend_request'   then 'Friend request'
      when 'friend_accepted'  then 'New friend'
      when 'event_invite'     then 'You''re invited'
      when 'here_now'         then 'Here now'
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.upsert_place(text,text,text,double precision,double precision)', 'public.save_place(uuid,boolean)',
    'public.get_my_places()', 'public.check_in(uuid,int,text,boolean)', 'public.check_out()', 'public.get_here_now()',
    'public.create_event(text,timestamptz,text,text,int,uuid,int,text,uuid[],uuid)', 'public.get_events(int,uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.can_see_checkin(uuid,uuid)', 'public.sweep_checkins()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
