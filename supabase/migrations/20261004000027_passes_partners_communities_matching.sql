-- Venue passes, partner venue nudges, joining by community, the activity light, and smarter matching.

-- =====================================================================
-- 1. Venue passes: each confirmed venue gets 100 single-use codes to hand out as it likes
-- =====================================================================
alter table public.venues add column if not exists pass_allowance int not null default 100 check (pass_allowance between 0 and 10000);
alter table public.invite_codes add column if not exists venue_id uuid references public.venues(id) on delete set null;
alter table public.invite_codes drop constraint if exists invite_codes_kind_check;
alter table public.invite_codes add constraint invite_codes_kind_check check (kind in ('single','limited','personal','community'));

create or replace function public.venue_passes_left(p_venue uuid)
returns int language sql stable security definer set search_path = public as $$
  select greatest(0, v.pass_allowance - (select count(*)::int from invite_codes c where c.venue_id = v.id))
  from venues v where v.id = p_venue;
$$;

create or replace function public.owner_create_passes(p_venue uuid, p_count int)
returns text[] language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_left int;
  v_label text;
  out_codes text[] := '{}';
  v text;
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  perform 1 from venues where id = p_venue for update;
  v_left := venue_passes_left(p_venue);
  if v_left <= 0 then raise exception 'You''ve used all your passes. Ask Based for more.'; end if;
  select pl.name into v_label from venues vn join places pl on pl.id = vn.place_id where vn.id = p_venue;
  for i in 1..least(greatest(coalesce(p_count, 1), 1), v_left, 50) loop
    v := new_invite_code();
    insert into invite_codes (code, kind, source_label, max_uses, created_by, venue_id)
    values (v, 'single', left(v_label, 60), 1, me, p_venue);
    out_codes := out_codes || v;
  end loop;
  return out_codes;
end $$;

create or replace function public.get_venue_passes(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'allowance', (select pass_allowance from venues where id = p_venue),
    'left', venue_passes_left(p_venue),
    'joined', (select count(*) from invite_redemptions r join invite_codes c on c.code = r.code where c.venue_id = p_venue),
    'codes', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', c.code, 'used', c.uses > 0, 'active', c.active, 'created_at', c.created_at,
                'joined', (select pr.display_name from invite_redemptions r join profiles pr on pr.id = r.user_id where r.code = c.code limit 1))
              order by c.created_at desc, c.code), '[]')
              from invite_codes c where c.venue_id = p_venue));
end $$;

create or replace function public.admin_set_pass_allowance(p_venue uuid, p_allowance int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update venues set pass_allowance = greatest(0, least(coalesce(p_allowance, 100), 10000)) where id = p_venue;
end $$;

create or replace function public.admin_venues()
returns table (venue_id uuid, name text, staff text, pass_allowance int, passes_made int, joined int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select v.id, pl.name,
         (select string_agg(p.display_name || ' (' || s.role || ')', ', ') from venue_staff s join profiles p on p.id = s.user_id where s.venue_id = v.id),
         v.pass_allowance,
         (select count(*)::int from invite_codes c where c.venue_id = v.id),
         (select count(*)::int from invite_redemptions r join invite_codes c on c.code = r.code where c.venue_id = v.id)
  from venues v join places pl on pl.id = v.place_id order by pl.name;
end $$;

-- =====================================================================
-- 2. Partner venues near you (founding venues), for plans and first meets
-- =====================================================================
create or replace function public.get_partner_venues(p_km int default 15)
returns table (venue_id uuid, place_id uuid, name text, address text, lat double precision, lng double precision,
               distance_km double precision, friends_here int)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  select * into v from profiles where id = me;
  return query
  select vn.id, pl.id, pl.name, pl.address, pl.lat, pl.lng,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1)::double precision end,
         (select count(*)::int from checkins c where c.place_id = pl.id and c.until > now() and can_see_checkin(c.user_id, me))
  from venues vn join places pl on pl.id = vn.place_id
  where not is_barred(me, pl.id)
    and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= coalesce(p_km, 15))
  order by case when v.lat is null then 0 else haversine_km(v.lat, v.lng, pl.lat, pl.lng) end
  limit 20;
end $$;

-- =====================================================================
-- 3. Joining by community (a verified school or work email gets straight in)
-- =====================================================================
create table if not exists public.communities (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 60),
  domains    text[] not null check (cardinality(domains) between 1 and 10),
  code       text references public.invite_codes(code) on delete set null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.communities enable row level security;  -- functions only

create or replace function public.admin_add_community(p_name text, p_domains text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  v_code text := new_invite_code();
  v_id uuid;
  v_domains text[];
begin
  select array_agg(distinct lower(regexp_replace(btrim(d), '^@', ''))) into v_domains
  from unnest(p_domains) d where btrim(d) ~ '^@?[A-Za-z0-9.-]+\.[A-Za-z]{2,}$';
  if v_domains is null then raise exception 'Add at least one email domain, like ucalgary.ca'; end if;
  insert into invite_codes (code, kind, source_label, max_uses, created_by)
  values (v_code, 'community', left(btrim(p_name), 60), 10000, me);
  insert into communities (name, domains, code) values (left(btrim(p_name), 60), v_domains, v_code) returning id into v_id;
  return v_id;
end $$;

create or replace function public.admin_communities()
returns table (id uuid, name text, domains text[], active boolean, joined int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.id, c.name, c.domains, c.active, (select count(*)::int from invite_redemptions r where r.code = c.code)
  from communities c order by c.created_at desc;
end $$;

create or replace function public.admin_set_community_active(p_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update communities set active = p_active where id = p_id;
  update invite_codes set active = p_active where code = (select code from communities where id = p_id);
end $$;

-- Called by the door screen: if my verified email belongs to a community, let me in
create or replace function public.redeem_community()
returns text language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := auth.uid();
  v_email text;
  v_domain text;
  c communities;
begin
  if me is null then return null; end if;
  if exists (select 1 from invite_redemptions where user_id = me) then return null; end if;
  select lower(u.email) into v_email from auth.users u where u.id = me and u.email_confirmed_at is not null;
  if v_email is null then return null; end if;
  v_domain := split_part(v_email, '@', 2);
  select * into c from communities cm
  where cm.active and exists (select 1 from unnest(cm.domains) d where v_domain = d or v_domain like '%.' || d)
  order by cm.created_at limit 1;
  if c.id is null or c.code is null then return null; end if;
  update invite_codes set uses = uses + 1 where code = c.code;
  insert into invite_redemptions (user_id, code, code_kind, source_label) values (me, c.code, 'community', c.name);
  return c.name;
end $$;

-- =====================================================================
-- 4. The activity light (built now, off until you switch it on in The door)
-- =====================================================================
insert into public.app_settings (key, value) values ('show_activity_light', 'false') on conflict (key) do nothing;

create or replace function public.my_activity()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_show boolean := coalesce((select (value)::text::boolean from app_settings where key = 'show_activity_light'), false);
  v_tier text;
begin
  if not v_show then return jsonb_build_object('show', false); end if;
  v_tier := effective_tier(me);
  return jsonb_build_object('show', true,
    'light', case v_tier when 'healthy' then 'green' when 'slipping' then 'yellow' else 'red' end,
    'tip', case v_tier
             when 'healthy' then 'You''re talking to your matches, so everyone can see you.'
             when 'slipping' then 'Some matches are waiting on you. Reply or end them kindly to stay fully visible.'
             else 'You''re being shown to fewer people because matches went quiet. Real conversations bring you back, even short ones.' end);
end $$;

create or replace function public.admin_set_activity_light(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  insert into app_settings (key, value) values ('show_activity_light', to_jsonb(coalesce(p_on, false)))
  on conflict (key) do update set value = excluded.value;
end $$;

-- my_access also reports the light setting (for The door)
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invite_only', invite_only(),
    'full_access_for_new', full_access_for_new(),
    'show_activity_light', coalesce((select (value)::text::boolean from app_settings where key = 'show_activity_light'), false),
    'redeemed', exists (select 1 from invite_redemptions where user_id = auth.uid()),
    'has_profile', exists (select 1 from profiles where id = auth.uid()));
$$;

-- =====================================================================
-- 5. Smarter matching: per-person weights learned from what they actually like
-- =====================================================================
create table if not exists public.user_match_weights (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  wi real not null default 1.0,   -- shared interests
  wt real not null default 1.0,   -- temperament (how they answered the scenarios)
  ws real not null default 1.0,   -- free time overlap
  wd real not null default 1.0,   -- closeness
  wy real not null default 1.0,   -- style (creates vs mostly reads)
  samples int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.user_match_weights enable row level security;  -- never readable by clients

create or replace function public.my_match_weights(p_user uuid)
returns table (wi real, wt real, ws real, wd real, wy real)
language sql stable security definer set search_path = public as $$
  select coalesce(w.wi, 1), coalesce(w.wt, 1), coalesce(w.ws, 1), coalesce(w.wd, 1), coalesce(w.wy, 1)
  from (select 1) x left join user_match_weights w on w.user_id = p_user;
$$;

-- 0..1 scores for each signal between two people
create or replace function public.match_features(p_a uuid, p_b uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with a as (select * from profiles where id = p_a), b as (select * from profiles where id = p_b),
  st as (
    select p.id,
           (select count(*) from posts where author_id = p.id and created_at > now() - interval '60 days') as made,
           (select count(*) from reactions where user_id = p.id and created_at > now() - interval '60 days')
         + (select count(*) from comments where author_id = p.id and created_at > now() - interval '60 days') as took
    from profiles p where p.id in (p_a, p_b)
  )
  select jsonb_build_object(
    'interests', least(1.0, (select count(*) from user_topics x join user_topics y on y.topic_id = x.topic_id
                              where x.user_id = p_a and y.user_id = p_b) / 5.0),
    'temperament', coalesce((select count(*) filter (where ka.value = kb.value)::real / nullif(count(*), 0)
                             from a, b, jsonb_each(a.scenario_answers) ka join jsonb_each(b.scenario_answers) kb on kb.key = ka.key), 0.5),
    'schedule', least(1.0, (select availability_overlap(a.availability, b.availability) from a, b) / 6.0),
    'distance', (select case when a.lat is null or b.lat is null then 0.5
                             else greatest(0.0, 1.0 - haversine_km(a.lat, a.lng, b.lat, b.lng) / 50.0) end from a, b),
    'style', 1.0 - abs((select made::real / (made + took + 1) from st where id = p_a)
                     - (select made::real / (made + took + 1) from st where id = p_b)));
$$;

-- Nightly: for each person with enough likes and passes, see which signals separate who they
-- like from who they pass on, and lean their matches that way (slowly, within limits).
create or replace function public.learn_match_weights()
returns int language plpgsql security definer set search_path = public as $$
declare
  u uuid;
  n int := 0;
  r record;
begin
  for u in
    select from_user from (
      select from_user from likes where created_at > now() - interval '60 days'
      union all
      select from_user from passes where created_at > now() - interval '60 days') x
    group by from_user having count(*) >= 10
  loop
    with acts as (
      select to_user, true as liked from likes where from_user = u and created_at > now() - interval '60 days'
      union all
      select to_user, false from passes where from_user = u and created_at > now() - interval '60 days'
    ),
    f as (select liked, match_features(u, to_user) as j from acts)
    select
      avg((j->>'interests')::real) filter (where liked) - avg((j->>'interests')::real) filter (where not liked) as di,
      avg((j->>'temperament')::real) filter (where liked) - avg((j->>'temperament')::real) filter (where not liked) as dt,
      avg((j->>'schedule')::real) filter (where liked) - avg((j->>'schedule')::real) filter (where not liked) as ds,
      avg((j->>'distance')::real) filter (where liked) - avg((j->>'distance')::real) filter (where not liked) as dd,
      avg((j->>'style')::real) filter (where liked) - avg((j->>'style')::real) filter (where not liked) as dy,
      count(*) as samples
    into r from f;
    if r.di is null then continue; end if;   -- needs both likes and passes
    insert into user_match_weights (user_id, wi, wt, ws, wd, wy, samples, updated_at)
    values (u,
            least(3, greatest(0.2, 1 + 3 * r.di)), least(3, greatest(0.2, 1 + 3 * r.dt)),
            least(3, greatest(0.2, 1 + 3 * r.ds)), least(3, greatest(0.2, 1 + 3 * r.dd)),
            least(3, greatest(0.2, 1 + 3 * r.dy)), r.samples, now())
    on conflict (user_id) do update set
      -- move halfway toward the new reading each night so one odd day doesn't swing it
      wi = (user_match_weights.wi + excluded.wi) / 2, wt = (user_match_weights.wt + excluded.wt) / 2,
      ws = (user_match_weights.ws + excluded.ws) / 2, wd = (user_match_weights.wd + excluded.wd) / 2,
      wy = (user_match_weights.wy + excluded.wy) / 2, samples = excluded.samples, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
select cron.schedule('learn-match-weights', '37 3 * * *', $$select public.learn_match_weights()$$);

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
  v_cap    constant int := 25;
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

create or replace function public.get_profile(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  st stances;
  va record;
begin
  select * into p from profiles where id = p_user;
  if p.id is null or (p.status <> 'active' and p.id <> me) then return null; end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    return null;
  end if;
  select * into st from stances where user_id = p_user;
  select a.storage_path, a.duration_ms, a.created_at, q.text as question into va
    from voice_answers a join voice_questions q on q.id = a.question_id where a.user_id = p_user;

  return jsonb_build_object(
    'id', p.id,
    'name', p.display_name,
    'age', extract(year from age(p.birthdate))::int,
    'is_me', p.id = me,
    'photos', (select coalesce(jsonb_agg(ph.storage_path order by ph.position), '[]')
                 from photos ph where ph.user_id = p.id and ph.review_status = 'approved'),
    'interests', (select coalesce(jsonb_agg(jsonb_build_object(
                     'name', t.name,
                     'shared', exists (select 1 from user_topics m where m.user_id = me and m.topic_id = t.id))
                   order by t.name), '[]')
                  from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = p.id),
    'recent_activity', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
                  select po.id, po.kind, po.body, t.name as topic, po.created_at
                  from posts po join topics t on t.id = po.topic_id
                  where po.author_id = p.id and po.status = 'visible'
                  order by po.created_at desc limit 10) x),
    'voice', case when va.storage_path is null then null else jsonb_build_object(
                 'question', va.question, 'path', va.storage_path, 'duration_ms', va.duration_ms,
                 'next_at', case when p.id = me then va.created_at + interval '24 hours' end) end,
    'stance', case when st.user_id is null then null else jsonb_build_object(
                 'statement', st.statement,
                 'my_verdict', (select verdict from stance_reactions where stance_user = p.id and reactor = me),
                 'agree', case when p.id = me then (select count(*) from stance_reactions where stance_user = p.id and verdict = 'agree') end,
                 'disagree', case when p.id = me then (select count(*) from stance_reactions where stance_user = p.id and verdict = 'disagree') end) end,
    'lately', lately(p.id),
    -- "Joined through <venue>": only for venue codes, and only if they haven't hidden it
    'joined_via', (select r.source_label from invite_redemptions r
                   where r.user_id = p.id and r.code_kind in ('single','limited','community') and r.source_label is not null
                     and coalesce(p.show_venue_badge, true)),
    -- Barred by 3+ unrelated venues in the last 12 months (lifted bars don't count)
    'venue_mark', venue_bar_groups(p.id) >= 3,
    -- Dating status is only visible to you and to other people who have dating on
    'dating_on', case when p.id = me or coalesce((select dating_on from profiles where id = me), false)
                      then p.dating_on end,
    'show_venue_badge', case when p.id = me and exists (select 1 from invite_redemptions r where r.user_id = p.id
                                 and r.code_kind in ('single','limited','community') and r.source_label is not null)
                             then coalesce(p.show_venue_badge, true) end
  );
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.owner_create_passes(uuid,int)', 'public.get_venue_passes(uuid)', 'public.admin_set_pass_allowance(uuid,int)',
    'public.admin_venues()', 'public.get_partner_venues(int)', 'public.admin_add_community(text,text[])',
    'public.admin_communities()', 'public.admin_set_community_active(uuid,boolean)', 'public.redeem_community()',
    'public.my_activity()', 'public.admin_set_activity_light(boolean)', 'public.my_access()',
    'public.get_match_batch(int)', 'public.get_profile(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.venue_passes_left(uuid)', 'public.my_match_weights(uuid)', 'public.match_features(uuid,uuid)',
    'public.learn_match_weights()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
