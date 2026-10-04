-- Dating is a switch, not the app.
--  * Based is about meeting people. Turning on "Dating" adds a view of people who might interest you.
--  * Only people who also have dating on can see you there, or see that yours is on.
--  * Existing members stay on; new members start with it off. Turning it off hides you from the
--    dating view right away; conversations you already have stay open.

alter table public.profiles add column if not exists dating_on boolean not null default false;
alter table public.profiles add column if not exists dating_on_since timestamptz;

-- Everyone who was already here signed up for dating, so they keep it
update public.profiles set dating_on = true, dating_on_since = coalesce(dating_on_since, now())
where status in ('active','paused') and not dating_on and created_at < now()
  and not exists (select 1 from app_settings where key = 'dating_switch_migrated');
insert into public.app_settings (key, value) values ('dating_switch_migrated', 'true') on conflict (key) do nothing;

create or replace function public.set_dating(p_on boolean)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update profiles set dating_on = coalesce(p_on, false),
                      dating_on_since = case when coalesce(p_on, false) then now() else null end
  where id = auth.uid();
  return coalesce(p_on, false);
end $$;

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
           abs(coalesce(s.desirability, 0.5) - coalesce(v_des, 0.5)) as gap
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
  ranked as (
    select scored.*,
           row_number() over (order by
             blk,
             case tier when 'healthy' then 0 when 'slipping' then 1 else 2 end,
             case when blk = 10 then -cardinality(shared) else 0 end,
             km * (1 + 2 * gap)) as rn
    from scored
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
   + (select count(*) from passes where from_user = me and created_at > now() - interval '1 day') >= 25 then
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
                   where r.user_id = p.id and r.code_kind in ('single','limited') and r.source_label is not null
                     and coalesce(p.show_venue_badge, true)),
    -- Barred by 3+ unrelated venues in the last 12 months (lifted bars don't count)
    'venue_mark', venue_bar_groups(p.id) >= 3,
    -- Dating status is only visible to you and to other people who have dating on
    'dating_on', case when p.id = me or coalesce((select dating_on from profiles where id = me), false)
                      then p.dating_on end,
    'show_venue_badge', case when p.id = me and exists (select 1 from invite_redemptions r where r.user_id = p.id
                                 and r.code_kind in ('single','limited') and r.source_label is not null)
                             then coalesce(p.show_venue_badge, true) end
  );
end $$;

-- Permissions
revoke all on function public.set_dating(boolean) from public, anon;
grant execute on function public.set_dating(boolean) to authenticated;
revoke all on function public.get_match_batch(int) from public, anon;
grant execute on function public.get_match_batch(int) to authenticated;
revoke all on function public.like_user(uuid) from public, anon;
grant execute on function public.like_user(uuid) to authenticated;
revoke all on function public.get_profile(uuid) from public, anon;
grant execute on function public.get_profile(uuid) to authenticated;

select count(*) filter (where dating_on) as dating_on, count(*) as members from public.profiles;
