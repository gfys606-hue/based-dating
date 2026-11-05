-- Nights out (Nov 3 2026):
--  1. Morning recap: the day after you check in somewhere, one quiet note:
--     "You were at <place> last night. How was it? Did you meet anybody? Any pictures you want to post?"
--     No list of people, ever.
--  2. Night ratings (instead of stars), two tracks:
--       Met new people:      Opened doors / Good room / Quiet room
--       Night with my people: Unforgettable / Good night / Just okay
--     Members see how a venue's nights usually go. Venues that rate well rise in suggestions; poor ones drop.
--  3. Venue plans: how many members plan to go where, tonight and the next couple of nights.
--     Friends going are named; everyone else is a number. Quiet mode = a number, even to friends.
--     A friend's plan aimed at people you're not part of = a number, no name.
--  4. Slow-night perks: venue staff post a members-only perk for a quiet night. It goes to every member
--     in the area (18+/drinking age), at most one perk notification per member per day; the rest show
--     as tags on venues in the plans view.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- 1. Visits and the morning recap
-- ---------------------------------------------------------------------
-- A "night" runs until 6 am: a 1 am check-in belongs to the evening before
create or replace function public.night_of(p_at timestamptz)
returns date language sql stable as $$
  select ((p_at at time zone 'America/Edmonton') - interval '6 hours')::date;
$$;

create table if not exists public.night_visits (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  place_id    uuid not null references public.places(id) on delete cascade,
  night       date not null,
  first_at    timestamptz not null default now(),
  recap_at    timestamptz,                      -- when the morning note went out
  track       text check (track in ('new_people','my_people')),
  rating      text check (rating in ('opened_doors','good_room','quiet_room','unforgettable','good_night','just_okay')),
  met_someone boolean,
  answered_at timestamptz,
  skipped     boolean not null default false,
  primary key (user_id, place_id, night),
  check (rating is null or (track = 'new_people') = (rating in ('opened_doors','good_room','quiet_room')))
);
create index if not exists night_visits_place on public.night_visits (place_id, answered_at desc);
alter table public.night_visits enable row level security;  -- functions only

create or replace function public.tg_checkin_visit()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into night_visits (user_id, place_id, night, first_at)
  values (new.user_id, new.place_id, night_of(new.started_at), new.started_at)
  on conflict do nothing;
  return null;
end $$;

drop trigger if exists checkin_visit on public.checkins;
create trigger checkin_visit after insert or update of place_id, started_at on public.checkins
for each row execute function public.tg_checkin_visit();

-- Morning note: one per member, about the last place they checked in last night
create or replace function public.send_night_recaps()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
  -- runs at ~10 am: "last night" is yesterday's evening
  v_last date := ((now() at time zone 'America/Edmonton') - interval '1 day')::date;
begin
  for r in
    select distinct on (v.user_id) v.user_id, v.place_id, pl.name
    from night_visits v
    join places pl on pl.id = v.place_id
    join profiles p on p.id = v.user_id and p.status = 'active'
    where v.night = v_last and v.recap_at is null
    order by v.user_id, v.first_at desc
  loop
    perform notify(r.user_id, 'night_recap',
      'You were at ' || r.name || ' last night. How was it? Did you meet anybody? Any pictures you want to post?');
    update night_visits set recap_at = now() where user_id = r.user_id and night = v_last;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'night-recaps') then perform cron.unschedule('night-recaps'); end if;
  perform cron.schedule('night-recaps', '7 16 * * *', 'select public.send_night_recaps()');  -- ~10 am Calgary
end $$;

-- The recap card in the app: your latest unanswered night (within 3 days)
create or replace function public.get_night_recap()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return (
    select jsonb_build_object('place_id', v.place_id, 'place_name', pl.name, 'night', v.night,
                              'last_night', v.night = ((now() at time zone 'America/Edmonton') - interval '1 day')::date)
    from night_visits v join places pl on pl.id = v.place_id
    where v.user_id = me and v.answered_at is null and not v.skipped
      and v.night < night_of(now())                         -- the night is over
      and v.night >= night_of(now()) - 3
    order by v.night desc, v.first_at desc
    limit 1);
end $$;

-- p_track: new_people | my_people; p_rating must belong to that track
create or replace function public.rate_night(p_place uuid, p_night date, p_track text, p_rating text, p_met boolean default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if p_track not in ('new_people','my_people') then raise exception 'Pick what kind of night it was.'; end if;
  if (p_track = 'new_people' and p_rating not in ('opened_doors','good_room','quiet_room'))
     or (p_track = 'my_people' and p_rating not in ('unforgettable','good_night','just_okay')) then
    raise exception 'Pick how it went.';
  end if;
  update night_visits
     set track = p_track, rating = p_rating, met_someone = p_met, answered_at = now(), skipped = false
   where user_id = me and place_id = p_place and night = p_night
     and night >= night_of(now()) - 7;
  if not found then raise exception 'That night is too far back to rate.'; end if;
end $$;

create or replace function public.skip_night_recap(p_place uuid, p_night date)
returns void language sql security definer set search_path = public as $$
  update night_visits set skipped = true where user_id = require_tester() and place_id = p_place and night = p_night;
$$;

-- ---------------------------------------------------------------------
-- 2. What a venue's nights are like
-- ---------------------------------------------------------------------
create or replace function public.rating_points(p_rating text)
returns int language sql immutable as $$
  select case p_rating when 'opened_doors' then 3 when 'unforgettable' then 3
                       when 'good_room' then 2 when 'good_night' then 2
                       when 'quiet_room' then 1 when 'just_okay' then 1 end;
$$;

create or replace function public.rating_word(p_rating text)
returns text language sql immutable as $$
  select case p_rating when 'opened_doors' then 'Opened doors' when 'good_room' then 'Good room'
                       when 'quiet_room' then 'Quiet room' when 'unforgettable' then 'Unforgettable'
                       when 'good_night' then 'Good night' when 'just_okay' then 'Just okay' end;
$$;

-- Ranking score for suggestions (last 90 days). Pulled toward "good" (2.0) until there are enough nights,
-- so one bad night can't sink a new venue and one great night can't crown it.
create or replace function public.venue_night_score(p_place uuid)
returns float8 language sql stable security definer set search_path = public as $$
  select (coalesce(sum(rating_points(v.rating)), 0) + 2.0 * 5) / (count(v.rating) + 5)
  from night_visits v
  where v.place_id = p_place and v.rating is not null and v.answered_at > now() - interval '90 days';
$$;

-- What members see: the most common answer for each kind of night, once there are 3+ ratings
create or replace function public.venue_night_summary(p_place uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nights', (select count(*) from night_visits v where v.place_id = p_place and v.rating is not null
                 and v.answered_at > now() - interval '90 days'),
    'new_people', (select rating_word(v.rating) from night_visits v
                   where v.place_id = p_place and v.track = 'new_people' and v.answered_at > now() - interval '90 days'
                   group by v.rating
                   order by count(*) desc, max(rating_points(v.rating)) desc limit 1),
    'my_people', (select rating_word(v.rating) from night_visits v
                  where v.place_id = p_place and v.track = 'my_people' and v.answered_at > now() - interval '90 days'
                  group by v.rating
                  order by count(*) desc, max(rating_points(v.rating)) desc limit 1))
  where (select count(*) from night_visits v where v.place_id = p_place and v.rating is not null
           and v.answered_at > now() - interval '90 days') >= 3;
$$;

create or replace function public.venue_night_label(p_place uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when s is null then null
    when s ->> 'new_people' is not null and s ->> 'my_people' is not null
      then 'Usually: ' || (s ->> 'new_people') || ' · ' || (s ->> 'my_people')
    else 'Usually: ' || coalesce(s ->> 'new_people', s ->> 'my_people') end
  from (select venue_night_summary(p_place) as s) x;
$$;

-- Partner venues: featured first, then how members' nights there have gone, then distance
-- (redefines get_partner_venues from 20261019000034; adds the night label)
drop function if exists public.get_partner_venues(int);
create or replace function public.get_partner_venues(p_km int default 15)
returns table (venue_id uuid, place_id uuid, name text, address text, lat double precision, lng double precision,
               distance_km double precision, friends_here int, featured boolean, nights text, perk text)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  if not bars_ok(me) then return; end if;
  select * into v from profiles where id = me;
  return query
  select vn.id, pl.id, pl.name, pl.address, pl.lat, pl.lng,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1)::double precision end,
         (select count(*)::int from checkins c where c.place_id = pl.id and c.until > now() and can_see_checkin(c.user_id, me)),
         coalesce(vn.featured_until > now(), false),
         venue_night_label(pl.id),
         (select pk.title from venue_perks pk where pk.venue_id = vn.id and pk.night = night_of(now()) and pk.active limit 1)
  from venues vn join places pl on pl.id = vn.place_id
  where not is_barred(me, pl.id)
    and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= coalesce(p_km, 15))
  order by coalesce(vn.featured_until > now(), false) desc,
           round(venue_night_score(pl.id)::numeric * 2) desc,   -- half-point bands so distance still matters
           case when v.lat is null then 0 else haversine_km(v.lat, v.lng, pl.lat, pl.lng) end
  limit 20;
end $$;

-- ---------------------------------------------------------------------
-- 4. Slow-night perks (table first: the plans view reads it)
-- ---------------------------------------------------------------------
create table if not exists public.venue_perks (
  id          uuid primary key default gen_random_uuid(),
  venue_id    uuid not null references public.venues(id) on delete cascade,
  night       date not null,
  title       text not null check (char_length(title) between 3 and 80),
  details     text check (char_length(details) <= 300),
  created_by  uuid references public.profiles(id) on delete set null,
  active      boolean not null default true,
  reached     int not null default 0,          -- members who got the notification (staff see this; members never do)
  created_at  timestamptz not null default now(),
  unique (venue_id, night)
);
alter table public.venue_perks enable row level security;  -- functions only

-- Staff post tonight's (or a coming night's) perk. One per venue per night.
create or replace function public.post_venue_perk(p_venue uuid, p_title text, p_details text default null, p_night date default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_night date := coalesce(p_night, night_of(now()));
  v_place places;
  v_id uuid;
  r record;
  n int := 0;
  v_day text;
begin
  if not is_venue_staff(p_venue, me) then raise exception 'Only this venue''s staff can post perks.'; end if;
  if v_night < night_of(now()) or v_night > night_of(now()) + 7 then raise exception 'Pick tonight or a night this week.'; end if;
  if blocked_term_in(coalesce(p_title, '') || ' ' || coalesce(p_details, '')) is not null then
    raise exception 'Keep it clean: that wording isn''t allowed.';
  end if;
  if cardinality(detect_contact(coalesce(p_title, '') || ' ' || coalesce(p_details, ''))) > 0 then
    raise exception 'Perks can''t include links or contact info. Members find you in the app.';
  end if;
  if exists (select 1 from venue_perks where venue_id = p_venue and night = v_night and active) then
    raise exception 'You already have a perk up for that night.';
  end if;
  select pl.* into v_place from venues vn join places pl on pl.id = vn.place_id where vn.id = p_venue;

  insert into venue_perks (venue_id, night, title, details, created_by)
  values (p_venue, v_night, btrim(p_title), nullif(btrim(coalesce(p_details, '')), ''), me)
  on conflict (venue_id, night) do update
     set title = excluded.title, details = excluded.details, created_by = me, active = true, created_at = now()
  returning id into v_id;

  v_day := case when v_night = night_of(now()) then 'tonight'
                else 'on ' || to_char(v_night, 'FMDay') end;

  -- every member in the area who's old enough; at most one perk notification per member per day
  for r in
    select u.id from profiles u
    where u.status = 'active' and u.lat is not null and u.id <> me
      and haversine_km(u.lat, u.lng, v_place.lat, v_place.lng) <= 25
      and bars_ok(u.id)
      and not is_barred(u.id, v_place.id)
      and not exists (select 1 from notifications nt where nt.user_id = u.id and nt.kind = 'perk'
                      and nt.created_at > now() - interval '20 hours')
  loop
    perform notify(r.id, 'perk', v_place.name || ' ' || v_day || ' for members: ' || btrim(p_title));
    n := n + 1;
  end loop;
  update venue_perks set reached = reached + n where id = v_id;
  return n;
end $$;

create or replace function public.end_venue_perk(p_perk uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select venue_id into v from venue_perks where id = p_perk;
  if v is null or not is_venue_staff(v, auth.uid()) then raise exception 'Not allowed.'; end if;
  update venue_perks set active = false where id = p_perk;
end $$;

create or replace function public.get_venue_perks(p_venue uuid)
returns table (perk_id uuid, night date, title text, details text, active boolean, reached int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_venue_staff(p_venue, auth.uid()) then raise exception 'Not allowed.'; end if;
  return query select pk.id, pk.night, pk.title, pk.details, pk.active, pk.reached, pk.created_at
               from venue_perks pk where pk.venue_id = p_venue and pk.night >= night_of(now()) - 14
               order by pk.night desc;
end $$;

-- ---------------------------------------------------------------------
-- 3. Venue plans: who's heading where, tonight and the next couple of nights
-- ---------------------------------------------------------------------
-- Everyone going to an event (the creator counts as going)
create or replace function public.event_goers(p_event uuid)
returns table (user_id uuid) language sql stable security definer set search_path = public as $$
  select e.creator_id from events e where e.id = p_event
  union
  select r.user_id from event_rsvps r where r.event_id = p_event and r.status = 'going';
$$;

-- One row per place per night. p_days = how many nights to cover (1 = tonight only, max 4).
create or replace function public.get_venue_plans(p_days int default 3, p_km int default 25)
returns table (place_id uuid, name text, address text, lat double precision, lng double precision,
               night date, going int, friends jsonb, me_going boolean, partner boolean,
               perk text, perk_details text, nights text)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_from date := night_of(now());
  v_to date := night_of(now()) + least(greatest(coalesce(p_days, 3), 1), 4) - 1;
  v_bars boolean := bars_ok(me);
begin
  select * into v from profiles where id = me;
  return query
  with goers as (
    select e.id as event_id, e.place_id, night_of(e.starts_at) as night, g.user_id
    from events e
    cross join lateral event_goers(e.id) g
    join profiles u on u.id = g.user_id and u.status = 'active'
    where e.status = 'active' and e.place_id is not null
      and e.starts_at > now() - interval '3 hours'
      and night_of(e.starts_at) between v_from and v_to
      -- blocked either way: they don't count for you at all
      and not exists (select 1 from blocks b where (b.blocker = g.user_id and b.blocked = me)
                                             or (b.blocker = me and b.blocked = g.user_id))
  ), per_person as (
    -- one person, one place, one night (even if they're in two plans there)
    select gg.place_id, gg.night, gg.user_id,
           bool_or(can_see_event(gg.event_id, me)) as visible
    from goers gg
    group by gg.place_id, gg.night, gg.user_id
  ), agg as (
    select pp.place_id, pp.night,
           count(*)::int as going,
           bool_or(pp.user_id = me) as me_going,
           coalesce(jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.display_name,
                       'photo', (select ph.storage_path from photos ph where ph.user_id = u.id and ph.position = 1 and ph.review_status = 'approved'))
                     order by u.display_name)
                    filter (where pp.user_id <> me and pp.visible and are_friends(me, pp.user_id) and not is_quiet(pp.user_id)),
                    '[]'::jsonb) as friends
    from per_person pp join profiles u on u.id = pp.user_id
    group by pp.place_id, pp.night
  ), perk_rows as (
    select vn.place_id, pk.night, pk.title, pk.details
    from venue_perks pk join venues vn on vn.id = pk.venue_id
    where v_bars and pk.active and pk.night between v_from and v_to
  ), keys as (
    select a.place_id, a.night from agg a
    union
    select pr.place_id, pr.night from perk_rows pr
  )
  select pl.id, pl.name, pl.address, pl.lat, pl.lng, k.night,
         coalesce(a.going, 0), coalesce(a.friends, '[]'::jsonb), coalesce(a.me_going, false),
         exists (select 1 from venues vn where vn.place_id = pl.id),
         pr.title, pr.details,
         venue_night_label(pl.id)
  from keys k
  join places pl on pl.id = k.place_id
  left join agg a on a.place_id = k.place_id and a.night = k.night
  left join perk_rows pr on pr.place_id = k.place_id and pr.night = k.night
  where not is_barred(me, pl.id)
    and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= coalesce(p_km, 25))
    -- bars and their perks only for members of drinking age; anyone can see plans at other places
    and (v_bars or not exists (select 1 from venues vn where vn.place_id = pl.id))
  order by k.night, coalesce(a.going, 0) desc, jsonb_array_length(coalesce(a.friends, '[]'::jsonb)) desc, pl.name
  limit 120;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.get_night_recap()', 'public.rate_night(uuid,date,text,text,boolean)', 'public.skip_night_recap(uuid,date)',
    'public.get_partner_venues(int)', 'public.venue_night_summary(uuid)',
    'public.post_venue_perk(uuid,text,text,date)', 'public.end_venue_perk(uuid)', 'public.get_venue_perks(uuid)',
    'public.get_venue_plans(int,int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.send_night_recaps()', 'public.event_goers(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
