-- Group-based matching (priority 5, Oct 19 2026): fewer but stronger Ouch matches.
-- People you already share real ground with (the same Herd, the same events, the same regular spots)
-- rank ahead of strangers who only look good on paper. Nothing else about matching changes.
-- Safe to re-run.

-- How much real-world ground two people share: common Herds, events both RSVP'd to (60 days),
-- and watering holes both have saved. Each counts once.
create or replace function public.shared_ground(p_x uuid, p_y uuid)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from circle_members a join circle_members b on b.circle_id = a.circle_id
           where a.user_id = p_x and b.user_id = p_y)
       + (select count(*)::int from event_rsvps a join event_rsvps b on b.event_id = a.event_id
            join events e on e.id = a.event_id
           where a.user_id = p_x and b.user_id = p_y and e.starts_at > now() - interval '60 days')
       + (select count(*)::int from saved_places a join saved_places b on b.place_id = a.place_id
           where a.user_id = p_x and b.user_id = p_y);
$$;
revoke all on function public.shared_ground(uuid, uuid) from public, anon, authenticated;

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
           match_features(me, c.id) as f,
           shared_ground(me, c.id) as ground
    from profiles c
    left join user_scores s on s.user_id = c.id
    where c.id <> me
      and c.status = 'active'
      and c.dating_on
      and c.city = v.city                    -- the city you picked
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
              + 1.2 * least(ground, 4)       -- shared Herds, events, regular spots: fewer, stronger matches
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

revoke all on function public.get_match_batch(int) from public, anon;
grant execute on function public.get_match_batch(int) to authenticated;
