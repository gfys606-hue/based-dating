-- Who sees each event + quiet mode + per-friend sharing.
--  * Every event has an audience: public (nearby), circle, friends, inner (my inner circle) or custom (picked friends).
--  * Quiet mode hides your plans and circles from everyone (inner circle included) until it ends.
--  * Per-friend sharing overrides the presets for one person (or goes back to the preset).

alter table public.events add column if not exists audience text not null default 'public';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'events_audience_check') then
    alter table public.events add constraint events_audience_check
      check (audience in ('public','circle','friends','inner','custom'));
  end if;
end $$;
update public.events set audience = 'circle' where circle_id is not null and audience = 'public';

create table if not exists public.event_invitees (
  event_id uuid references public.events(id) on delete cascade,
  user_id  uuid references public.profiles(id) on delete cascade,
  primary key (event_id, user_id)
);
alter table public.event_invitees enable row level security;  -- functions only

alter table public.profiles add column if not exists quiet_until timestamptz;  -- 'infinity' = until turned off

-- What user_a shares with user_b (and b with a) when set; null = follow the presets
alter table public.friendships add column if not exists a_share jsonb;
alter table public.friendships add column if not exists b_share jsonb;

create or replace function public.is_quiet(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select quiet_until > now() from profiles where id = p_user), false);
$$;

create or replace function public.are_friends(p_x uuid, p_y uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships where user_a = least(p_x, p_y) and user_b = greatest(p_x, p_y) and status = 'accepted');
$$;

create or replace function public.can_see_event(p_event uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from events e
    where e.id = p_event
      and not exists (select 1 from blocks b where (b.blocker = p_viewer and b.blocked = e.creator_id)
                                              or (b.blocker = e.creator_id and b.blocked = p_viewer))
      and (e.creator_id = p_viewer
           or exists (select 1 from event_rsvps r where r.event_id = e.id and r.user_id = p_viewer)
           or case e.audience
                when 'public'  then true
                when 'circle'  then is_circle_member(e.circle_id, p_viewer)
                when 'friends' then are_friends(e.creator_id, p_viewer)
                when 'inner'   then in_inner_circle(e.creator_id, p_viewer)
                when 'custom'  then exists (select 1 from event_invitees i where i.event_id = e.id and i.user_id = p_viewer)
                else false end));
$$;

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
drop function if exists public.get_events(int, uuid);
create or replace function public.get_events(p_km int default 50, p_circle uuid default null)
returns table (event_id uuid, title text, details text, topic text, place_name text,
               starts_at timestamptz, distance_km int, going int, capacity int,
               my_rsvp text, mine boolean, circle_id uuid, circle_name text, creator_name text,
               audience text, invited_count int)
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
              then (select count(*)::int from event_invitees i where i.event_id = e.id) end
  from events e
  left join topics t on t.id = e.topic_id
  left join circles c on c.id = e.circle_id
  join profiles cr on cr.id = e.creator_id
  where e.status = 'active'
    and e.starts_at > now() - interval '2 hours'
    and (p_circle is null or e.circle_id = p_circle)
    and can_see_event(e.id, me)
    -- distance only limits public events; friends' plans show wherever they are
    and (e.audience <> 'public' or e.creator_id = me or e.lat is null or v.lat is null
         or haversine_km(v.lat, v.lng, e.lat, e.lng) <= p_km)
  order by
    (e.audience in ('inner','custom','friends')) desc,
    (exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = e.topic_id)) desc,
    e.starts_at
  limit 100;
end $$;

drop function if exists public.create_event(text, timestamptz, text, text, int, uuid, int);
create or replace function public.create_event(
  p_title text, p_starts_at timestamptz, p_details text default null, p_place text default null,
  p_topic int default null, p_circle uuid default null, p_capacity int default null,
  p_audience text default null, p_invitees uuid[] default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_id uuid;
  v_aud text := coalesce(p_audience, case when p_circle is null then 'public' else 'circle' end);
  v_to uuid;
  v_msg text;
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
  insert into events (creator_id, circle_id, title, details, topic_id, place_name, starts_at, lat, lng, capacity, audience)
  values (me, p_circle, p_title, p_details, p_topic, p_place, p_starts_at, v.lat, v.lng, p_capacity, v_aud)
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

  -- Friends / inner circle / picked people get a heads-up (public and circle plans don't ping anyone)
  if v_aud in ('friends','inner','custom') then
    v_msg := v.display_name || ': ' || p_title
             || coalesce(' at ' || nullif(btrim(p_place), ''), '')
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

create or replace function public.rsvp_event(p_event uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  e events;
begin
  select * into e from events where id = p_event and status = 'active';
  if e.id is null or not can_see_event(p_event, me) then raise exception 'Event not found'; end if;
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

-- ---------------------------------------------------------------------
-- Quiet mode and per-friend sharing
-- ---------------------------------------------------------------------
-- p_hours: 0 or null = off, -1 = until I turn it off, otherwise that many hours
create or replace function public.set_quiet(p_hours int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare v timestamptz;
begin
  v := case when coalesce(p_hours, 0) = 0 then null
            when p_hours < 0 then 'infinity'::timestamptz
            else now() + make_interval(hours => least(p_hours, 24 * 30)) end;
  update profiles set quiet_until = v where id = auth.uid();
  return v;
end $$;

-- What I share with one friend. Pass null for both to go back to the presets.
create or replace function public.set_friend_sharing(p_user uuid, p_plans boolean, p_circles boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f friendships;
  v jsonb := case when p_plans is null and p_circles is null then null
                  else jsonb_build_object('plans', coalesce(p_plans, false), 'circles', coalesce(p_circles, false)) end;
begin
  f := friendship_between(me, p_user);
  if f.id is null or f.status <> 'accepted' then raise exception 'Only for friends.'; end if;
  if f.user_a = me then update friendships set a_share = v where id = f.id;
  else update friendships set b_share = v where id = f.id; end if;
end $$;

-- What p_owner shows p_viewer: quiet mode > per-person setting > inner circle > friends preset
create or replace function public.sharing_for(p_owner uuid, p_viewer uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  f friendships := friendship_between(p_owner, p_viewer);
  ov jsonb;
  vis jsonb;
begin
  if f.id is null or f.status <> 'accepted' or is_quiet(p_owner) then
    return '{"plans": false, "circles": false}';
  end if;
  ov := case when f.user_a = p_owner then f.a_share else f.b_share end;
  if ov is not null then return ov; end if;
  if (case when f.user_a = p_owner then f.a_inner else f.b_inner end) then
    return '{"plans": true, "circles": true}';
  end if;
  vis := coalesce((select friend_visibility from profiles where id = p_owner), '{}');
  return jsonb_build_object('plans', coalesce((vis ->> 'plans')::boolean, false),
                            'circles', coalesce((vis ->> 'circles')::boolean, false));
end $$;

create or replace function public.friend_card_extras(p_friend uuid, p_viewer uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb := sharing_for(p_friend, p_viewer);
begin
  return jsonb_build_object(
    'plans', case when not (s ->> 'plans')::boolean then null else (
      select coalesce(jsonb_agg(jsonb_build_object('title', x.title, 'starts_at', x.starts_at, 'place', x.place_name) order by x.starts_at), '[]')
      from (select e.title, e.starts_at, e.place_name from event_rsvps r join events e on e.id = r.event_id
            where r.user_id = p_friend and r.status = 'going' and e.status = 'active'
              and e.starts_at between now() - interval '3 hours' and now() + interval '30 days'
              and can_see_event(e.id, p_viewer)
            order by e.starts_at limit 3) x) end,
    'circles', case when not (s ->> 'circles')::boolean then null else (
      select coalesce(jsonb_agg(c.name order by c.name), '[]')
      from circle_members cm join circles c on c.id = cm.circle_id where cm.user_id = p_friend) end);
end $$;

-- friend_status: add what I share with them, and whether I'm in quiet mode
create or replace function public.friend_status(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f friendships;
  v_met text;
begin
  if me is null or p_user = me then return jsonb_build_object('status', 'self'); end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    return jsonb_build_object('status', 'unavailable');
  end if;
  f := friendship_between(me, p_user);
  if f.status = 'accepted' then
    return jsonb_build_object('status', 'friends', 'friendship_id', f.id,
      'inner', case when f.user_a = me then f.a_inner else f.b_inner end,
      'their_inner', in_inner_circle(p_user, me),
      'custom_share', (case when f.user_a = me then f.a_share else f.b_share end) is not null,
      'sharing', sharing_for(me, p_user),
      'quiet', is_quiet(me));
  elsif f.status = 'pending' then
    return jsonb_build_object('status', case when f.requested_by = me then 'outgoing' else 'incoming' end);
  end if;
  v_met := how_we_met(me, p_user);
  if f.status = 'declined' and f.requested_by = me and f.responded_at > now() - interval '30 days' then
    return jsonb_build_object('status', 'outgoing');
  end if;
  return jsonb_build_object('status', case when v_met is null then 'unavailable' else 'none' end, 'met', v_met);
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
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;

-- Search: only public events show up
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
                 where e.status = 'active' and e.starts_at > now() and e.audience = 'public'
                   and (e.title ilike pat or e.details ilike pat or t.name ilike pat)
                 order by e.starts_at limit 10) x),
    'listings', (select coalesce(jsonb_agg(x), '[]') from (
                 select l.id, l.title, l.price_cents, l.photo_path
                 from listings l
                 where l.status = 'active' and (l.title ilike pat or l.description ilike pat)
                 order by l.created_at desc limit 10) x)
  );
end $$;

-- Lately: only public plans, and nothing about plans or circles while quiet
create or replace function public.lately(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with topic_score as (
    select topic_id, sum(w) as score from (
      select po.topic_id, 3 as w from posts po
       where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 2 from comments c join posts po on po.id = c.post_id
       where c.author_id = p_user and c.status = 'visible' and c.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 1 from reactions r join posts po on po.id = r.post_id
       where r.user_id = p_user and r.created_at > now() - interval '30 days'
      union all
      select e.topic_id, 2 from event_rsvps r join events e on e.id = r.event_id
       where r.user_id = p_user and r.status = 'going' and e.topic_id is not null and r.created_at > now() - interval '30 days'
    ) x group by topic_id
  ),
  lines as (
    select 1 as ord, 'topic' as kind, 'Into ' || t.name || ' lately' as label, ts.score
      from topic_score ts join topics t on t.id = ts.topic_id
    union all
    select 2, 'event', 'Going to ' || e.title, 0
      from event_rsvps r join events e on e.id = r.event_id
     where r.user_id = p_user and r.status = 'going' and e.audience = 'public' and not is_quiet(p_user)
       and e.starts_at between now() and now() + interval '30 days'
    union all
    select 3, 'posts', 'Posted ' || count(*) || ' times this month', 0
      from posts po where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
     having count(*) >= 2
    union all
    select 4, 'circles', 'In ' || count(*) || case when count(*) = 1 then ' circle' else ' circles' end, 0
      from circle_members cm where cm.user_id = p_user and not is_quiet(p_user)
     having count(*) >= 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'label', label) order by ord, score desc), '[]')
  from (select * from lines order by ord, score desc limit 5) l;
$$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_events(int,uuid)',
    'public.create_event(text,timestamptz,text,text,int,uuid,int,text,uuid[])',
    'public.rsvp_event(uuid,text)', 'public.set_quiet(int)', 'public.set_friend_sharing(uuid,boolean,boolean)',
    'public.friend_status(uuid)', 'public.search_all(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.is_quiet(uuid)', 'public.are_friends(uuid,uuid)', 'public.can_see_event(uuid,uuid)',
    'public.sharing_for(uuid,uuid)', 'public.friend_card_extras(uuid,uuid)', 'public.lately(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
