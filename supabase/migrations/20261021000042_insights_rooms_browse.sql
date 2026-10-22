-- Three saved items from Oct 19 2026:
--  1. Owner-only insights: who's joining (city / age / source), top and growing interests per city,
--     the connection funnel (matches -> voice swaps -> same-room meets -> friendships), and which interests
--     connect people most. Aggregates only, never individual activity. Test profiles left out unless asked.
--  2. "Same room": when two members are checked in at the same place, both get a heads-up and see a partial
--     profile (age + interests, shared ones highlighted, no name or photo). Each says yes or no privately;
--     both yes = full profiles unlock and they can add each other right away. A "did you meet?" follow-up
--     comes the next day; both saying "friends" makes them friends. A no is never shown to the other person.
--  3. Browse: a two-way switch. On = you can browse people in your city and they can find you; off = neither.
--     Dating browse shows only people with Ouch on.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- 1. Insights
-- ---------------------------------------------------------------------
create or replace function public.admin_insights(p_city text default null, p_include_test boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_city text := coalesce(p_city, default_city());
  r jsonb;
begin
  perform require_admin();
  with
  people as (
    select p.* from profiles p
    where p.status in ('active','paused','onboarding') and (p_include_test or not p.is_test)),
  here as (select * from people where city = v_city),
  src as (
    select pe.id,
           coalesce(case when r.code_kind = 'personal' then 'Member invite' end, r.source_label,
                    case when r.user_id is null then 'No code' end, initcap(r.code_kind)) as source,
           pe.created_at
    from people pe left join invite_redemptions r on r.user_id = pe.id),
  connected as (   -- pairs who actually connected: talked on Ouch, or became friends
    select least(m.user_a, m.user_b) as x, greatest(m.user_a, m.user_b) as y from matches m where m.call_done
    union
    select f.user_a, f.user_b from friendships f where f.status = 'accepted'),
  cpairs as (
    select c.x, c.y from connected c
    where exists (select 1 from people where id = c.x) and exists (select 1 from people where id = c.y)),
  shared as (
    select a.topic_id, cp.x, cp.y from cpairs cp
    join user_topics a on a.user_id = cp.x
    join user_topics b on b.user_id = cp.y and b.topic_id = a.topic_id)
  select jsonb_build_object(
    'city', (select name from cities where slug = v_city),
    'include_test', p_include_test,
    'signups', jsonb_build_object(
      'total', (select count(*) from people),
      'last_30d', (select count(*) from people where created_at > now() - interval '30 days'),
      'by_city', (select coalesce(jsonb_agg(jsonb_build_object('label', coalesce(c.name, x.city), 'n', x.n) order by x.n desc), '[]')
                  from (select city, count(*) n from people group by city) x left join cities c on c.slug = x.city),
      'by_age', (select coalesce(jsonb_agg(jsonb_build_object('label', b, 'n', n) order by o), '[]') from (
                  select case when a < 25 then '18-24' when a < 30 then '25-29' when a < 35 then '30-34'
                              when a < 40 then '35-39' else '40+' end b,
                         min(a) o, count(*) n
                  from (select extract(year from age(birthdate))::int a from people) z group by 1) y),
      'by_source', (select coalesce(jsonb_agg(jsonb_build_object('label', source, 'n', n) order by n desc), '[]')
                    from (select source, count(*) n from src group by source) s)),
    'interests', jsonb_build_object(
      'top', (select coalesce(jsonb_agg(jsonb_build_object('label', name, 'n', n) order by n desc), '[]') from (
                select t.name, count(*) n from here h join user_topics ut on ut.user_id = h.id join topics t on t.id = ut.topic_id
                group by t.name order by count(*) desc limit 10) a),
      'growing', (select coalesce(jsonb_agg(jsonb_build_object('label', name, 'n', recent, 'before', before) order by recent - before desc), '[]') from (
                select t.name,
                       count(*) filter (where h.created_at > now() - interval '30 days') recent,
                       count(*) filter (where h.created_at <= now() - interval '30 days' and h.created_at > now() - interval '60 days') before
                from here h join user_topics ut on ut.user_id = h.id join topics t on t.id = ut.topic_id
                group by t.name
                having count(*) filter (where h.created_at > now() - interval '30 days') > 0
                order by count(*) filter (where h.created_at > now() - interval '30 days')
                       - count(*) filter (where h.created_at <= now() - interval '30 days' and h.created_at > now() - interval '60 days') desc
                limit 8) g)),
    'funnel', jsonb_build_object(   -- last 30 days, people in the count only
      'matches', (select count(*) from matches m where m.created_at > now() - interval '30 days'
                    and exists (select 1 from people where id = m.user_a) and exists (select 1 from people where id = m.user_b)),
      'voice_swaps', (select count(*) from matches m where m.voice_swapped_at > now() - interval '30 days'
                    and exists (select 1 from people where id = m.user_a) and exists (select 1 from people where id = m.user_b)),
      'room_meets', (select count(*) from room_meets rm where rm.matched_at > now() - interval '30 days'
                    and exists (select 1 from people where id = rm.user_a) and exists (select 1 from people where id = rm.user_b)),
      'friendships', (select count(*) from friendships f where f.status = 'accepted' and f.responded_at > now() - interval '30 days'
                    and exists (select 1 from people where id = f.user_a) and exists (select 1 from people where id = f.user_b))),
    'connect_most', jsonb_build_object(
      'pairs', (select count(*) from cpairs),
      'topics', (select coalesce(jsonb_agg(jsonb_build_object('label', name, 'n', n) order by n desc), '[]') from (
                  select t.name, count(*) n from shared s join topics t on t.id = s.topic_id
                  group by t.name order by count(*) desc limit 8) a),
      'combos', (select coalesce(jsonb_agg(jsonb_build_object('label', a || ' + ' || b, 'n', n) order by n desc), '[]') from (
                  select ta.name a, tb.name b, count(*) n
                  from shared s1 join shared s2 on s2.x = s1.x and s2.y = s1.y and s2.topic_id > s1.topic_id
                  join topics ta on ta.id = s1.topic_id join topics tb on tb.id = s2.topic_id
                  group by ta.name, tb.name order by count(*) desc limit 8) c))
  ) into r;
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 2. Same room
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists room_meets boolean not null default true;

create table if not exists public.room_meets (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null references public.places(id) on delete cascade,
  user_a      uuid not null references public.profiles(id) on delete cascade,
  user_b      uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  a_yes       boolean,
  b_yes       boolean,
  matched_at  timestamptz,
  followed_up boolean not null default false,
  a_met       boolean,
  b_met       boolean,
  a_friend    boolean,
  b_friend    boolean,
  check (user_a < user_b)
);
alter table public.room_meets enable row level security;  -- functions only
create index if not exists room_meets_a on public.room_meets (user_a, created_at);
create index if not exists room_meets_b on public.room_meets (user_b, created_at);

-- A check-in starts: pair this member with others here right now (at most 5 new pairs, once per 12 h per pair)
create or replace function public.tg_checkin_room()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  o record;
  v_place text;
  n int := 0;
begin
  if new.until <= now() then return null; end if;
  if tg_op = 'UPDATE' and old.place_id = new.place_id and old.until > now() then return null; end if;
  if not coalesce((select room_meets and status = 'active' from profiles where id = new.user_id), false) then return null; end if;
  select name into v_place from places where id = new.place_id;
  for o in
    select c.user_id from checkins c join profiles p on p.id = c.user_id
    where c.place_id = new.place_id and c.until > now() and c.user_id <> new.user_id
      and p.status = 'active' and p.room_meets and not is_quiet(c.user_id)
      and not exists (select 1 from blocks b where (b.blocker = new.user_id and b.blocked = c.user_id)
                                              or (b.blocker = c.user_id and b.blocked = new.user_id))
      and not exists (select 1 from room_meets r where r.user_a = least(new.user_id, c.user_id)
                        and r.user_b = greatest(new.user_id, c.user_id) and r.created_at > now() - interval '12 hours')
    order by c.started_at desc limit 5
  loop
    insert into room_meets (place_id, user_a, user_b)
    values (new.place_id, least(new.user_id, o.user_id), greatest(new.user_id, o.user_id));
    perform notify(new.user_id, 'room_meet', 'Another member is here at ' || coalesce(v_place, 'this spot') || '. Want to see who?');
    perform notify(o.user_id, 'room_meet', 'Another member just got to ' || coalesce(v_place, 'your spot') || '. Want to see who?');
    n := n + 1;
  end loop;
  return null;
end $$;

drop trigger if exists checkin_room on public.checkins;
create trigger checkin_room after insert or update of place_id, until on public.checkins
  for each row execute function public.tg_checkin_room();

-- My same-room meets: open ones (last 12 h) and recent matches. Name and photo only once both said yes.
create or replace function public.my_room_meets()
returns table (id uuid, place text, created_at timestamptz, other_age int, interests text[], shared text[],
               my_answer boolean, matched boolean, other_id uuid, other_name text, other_photo text,
               ask_followup boolean)
language sql stable security definer set search_path = public as $$
  select r.id, pl.name, r.created_at,
         extract(year from age(o.birthdate))::int,
         (select coalesce(array_agg(t.name order by t.name), '{}') from (
            select t.name from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = o.id
            order by exists (select 1 from user_topics m where m.user_id = auth.uid() and m.topic_id = ut.topic_id) desc, t.name
            limit 8) t),
         (select coalesce(array_agg(t.name order by t.name), '{}') from user_topics a
            join user_topics b on b.topic_id = a.topic_id and b.user_id = o.id join topics t on t.id = a.topic_id
           where a.user_id = auth.uid()),
         case when r.user_a = auth.uid() then r.a_yes else r.b_yes end,
         r.matched_at is not null,
         case when r.matched_at is not null then o.id end,
         case when r.matched_at is not null then o.display_name end,
         case when r.matched_at is not null then
           (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved') end,
         r.matched_at is not null
           and (r.matched_at at time zone 'America/Edmonton')::date < (now() at time zone 'America/Edmonton')::date
           and (case when r.user_a = auth.uid() then r.a_met else r.b_met end) is null
  from room_meets r
  join profiles o on o.id = case when r.user_a = auth.uid() then r.user_b else r.user_a end and o.status = 'active'
  join places pl on pl.id = r.place_id
  where auth.uid() in (r.user_a, r.user_b)
    and not exists (select 1 from blocks b where (b.blocker = auth.uid() and b.blocked = o.id) or (b.blocker = o.id and b.blocked = auth.uid()))
    and ((r.matched_at is null and r.created_at > now() - interval '12 hours'
          and (case when r.user_a = auth.uid() then r.a_yes else r.b_yes end) is distinct from false)
      or (r.matched_at is not null and r.matched_at > now() - interval '3 days'))
  order by r.created_at desc;
$$;

create or replace function public.answer_room_meet(p_id uuid, p_yes boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r room_meets;
begin
  select * into r from room_meets where id = p_id and me in (user_a, user_b) for update;
  if r.id is null or r.created_at < now() - interval '12 hours' then raise exception 'That one has passed.'; end if;
  if r.user_a = me then update room_meets set a_yes = p_yes where id = r.id;
  else update room_meets set b_yes = p_yes where id = r.id; end if;
  select * into r from room_meets where id = r.id;
  if r.a_yes and r.b_yes and r.matched_at is null then
    update room_meets set matched_at = now() where id = r.id;
    perform notify(r.user_a, 'room_match', 'You both said yes. ' || (select display_name from profiles where id = r.user_b) || ' is here: go say hi.');
    perform notify(r.user_b, 'room_match', 'You both said yes. ' || (select display_name from profiles where id = r.user_a) || ' is here: go say hi.');
    return true;
  end if;
  return false;
end $$;

-- Next day: did you meet? want to be friends? Both "friends" = friends.
create or replace function public.room_meet_followup(p_id uuid, p_met boolean, p_friend boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  r room_meets;
begin
  select * into r from room_meets where id = p_id and me in (user_a, user_b) and matched_at is not null for update;
  if r.id is null then raise exception 'Nothing to answer.'; end if;
  if r.user_a = me then update room_meets set a_met = p_met, a_friend = p_met and p_friend where id = r.id;
  else update room_meets set b_met = p_met, b_friend = p_met and p_friend where id = r.id; end if;
  select * into r from room_meets where id = r.id;
  if r.a_friend and r.b_friend then
    insert into friendships (user_a, user_b, requested_by, status, created_at, responded_at)
    values (r.user_a, r.user_b, me, 'accepted', now(), now())
    on conflict (user_a, user_b) do update set status = 'accepted', responded_at = now();
    perform notify(case when r.user_a = me then r.user_b else r.user_a end, 'friend_accepted',
      (select display_name from profiles where id = me) || ' wants to stay in touch too. You''re friends now.');
    return 'friends';
  end if;
  return 'saved';
end $$;

-- Daily at noon: nudge last night's matched pairs for the follow-up
create or replace function public.room_meet_followups()
returns int language plpgsql security definer set search_path = public as $$
declare r room_meets; n int := 0;
begin
  for r in select * from room_meets
            where matched_at is not null and not followed_up
              and (matched_at at time zone 'America/Edmonton')::date < (now() at time zone 'America/Edmonton')::date loop
    perform notify(r.user_a, 'room_followup', 'Did you meet ' || (select display_name from profiles where id = r.user_b) || '? Tell us in Spots.');
    perform notify(r.user_b, 'room_followup', 'Did you meet ' || (select display_name from profiles where id = r.user_a) || '? Tell us in Spots.');
    update room_meets set followed_up = true where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('room-followups', '7 18 * * *', 'select public.room_meet_followups()');  -- 12:07 Calgary (UTC-6)
  end if;
end $$;

-- Meeting in the same room counts as having met: you can add each other right away
create or replace function public.how_we_met(p_x uuid, p_y uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select 'You matched and talked' from matches m
      where least(m.user_a, m.user_b) = least(p_x, p_y) and greatest(m.user_a, m.user_b) = greatest(p_x, p_y)
        and m.call_done and coalesce(m.end_reason, '') <> 'report' limit 1),
    (select 'Met at ' || pl.name from room_meets r join places pl on pl.id = r.place_id
      where r.user_a = least(p_x, p_y) and r.user_b = greatest(p_x, p_y) and r.matched_at is not null
      order by r.matched_at desc limit 1),
    (select 'Both in ' || c.name from circle_members a join circle_members b on b.circle_id = a.circle_id
       join circles c on c.id = a.circle_id
      where a.user_id = p_x and b.user_id = p_y limit 1),
    (select 'Both at ' || e.title from event_rsvps a join event_rsvps b on b.event_id = a.event_id
       join events e on e.id = a.event_id
      where a.user_id = p_x and b.user_id = p_y and e.status = 'active'
        and e.starts_at > now() - interval '60 days'
      order by e.starts_at desc limit 1));
$$;

-- ---------------------------------------------------------------------
-- 3. Browse (two-way)
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists browse_on boolean not null default false;
-- test profiles are there to be browsed
update public.profiles set browse_on = true where is_test and not browse_on;

create or replace function public.browse_people(p_dating boolean default false, p_limit int default 40, p_offset int default 0)
returns table (user_id uuid, name text, age int, photo text, distance_km int, shared text[], shared_count int)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  select * into v from profiles where id = me;
  if v.id is null or v.status <> 'active' then return; end if;
  if not v.browse_on then raise exception 'Turn on Browse to look around (and be found).'; end if;
  if p_dating and not v.dating_on then raise exception 'Turn on Ouch to browse for dating.'; end if;
  return query
  select p.id, p.display_name, extract(year from age(p.birthdate))::int,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         case when v.lat is null or p.lat is null then null else greatest(1, round(haversine_km(v.lat, v.lng, p.lat, p.lng)))::int end,
         (select coalesce(array_agg(t.name order by t.name), '{}') from user_topics a
            join user_topics b on b.topic_id = a.topic_id and b.user_id = p.id join topics t on t.id = a.topic_id
           where a.user_id = me),
         (select count(*)::int from user_topics a join user_topics b on b.topic_id = a.topic_id and b.user_id = p.id where a.user_id = me)
  from profiles p
  where p.id <> me and p.status = 'active' and p.browse_on and p.city = v.city
    and effective_tier(p.id) <> 'invisible'
    and (not p_dating or (p.dating_on and p.gender = any (v.seeking) and v.gender = any (p.seeking)))
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
  order by 7 desc, 5 nulls last
  limit least(greatest(coalesce(p_limit, 40), 1), 100) offset greatest(coalesce(p_offset, 0), 0);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_insights(text,boolean)', 'public.my_room_meets()', 'public.answer_room_meet(uuid,boolean)',
    'public.room_meet_followup(uuid,boolean,boolean)', 'public.browse_people(boolean,int,int)', 'public.how_we_met(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke all on function public.room_meet_followups() from public, anon, authenticated;
end $$;
