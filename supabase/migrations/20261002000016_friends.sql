-- Friends: people you've crossed paths with (a match you've had a call with, a shared circle,
-- or the same event). Request + accept. Friends can message each other.
-- Each person also keeps an inner circle: inner-circle friends see everything (plans and circles);
-- other friends see only what you allow in "What friends can see".

create table if not exists public.friendships (
  id           uuid primary key default gen_random_uuid(),
  user_a       uuid not null references public.profiles(id) on delete cascade,  -- user_a < user_b
  user_b       uuid not null references public.profiles(id) on delete cascade,
  requested_by uuid not null references public.profiles(id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending','accepted','declined')),
  a_inner      boolean not null default false,  -- user_a has put user_b in their inner circle
  b_inner      boolean not null default false,  -- user_b has put user_a in their inner circle
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (user_a < user_b),
  unique (user_a, user_b)
);
create index if not exists friendships_b on public.friendships (user_b);

create table if not exists public.friend_messages (
  id            uuid primary key default gen_random_uuid(),
  friendship_id uuid not null references public.friendships(id) on delete cascade,
  sender_id     uuid not null references public.profiles(id) on delete cascade,
  body          text not null check (char_length(body) between 1 and 2000),
  created_at    timestamptz not null default now()
);
create index if not exists friend_messages_thread on public.friend_messages (friendship_id, created_at);

-- What regular (not inner-circle) friends can see. Inner circle always sees everything.
alter table public.profiles
  add column if not exists friend_visibility jsonb not null default '{"plans": false, "circles": false}';

alter table public.friendships     enable row level security;  -- functions only
alter table public.friend_messages enable row level security;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.friendship_between(p_x uuid, p_y uuid)
returns public.friendships language sql stable security definer set search_path = public as $$
  select * from friendships where user_a = least(p_x, p_y) and user_b = greatest(p_x, p_y);
$$;

create or replace function public.is_friend_thread(p_friendship uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships f
    where f.id = p_friendship and f.status = 'accepted' and p_user in (f.user_a, f.user_b)
      and not exists (select 1 from blocks b where (b.blocker = f.user_a and b.blocked = f.user_b)
                                              or (b.blocker = f.user_b and b.blocked = f.user_a)));
$$;

-- Has p_owner put p_viewer in their inner circle?
create or replace function public.in_inner_circle(p_owner uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select case when f.user_a = p_owner then f.a_inner else f.b_inner end
                   from friendships f
                   where f.user_a = least(p_owner, p_viewer) and f.user_b = greatest(p_owner, p_viewer)
                     and f.status = 'accepted'), false);
$$;

-- How two people met (null = they haven't crossed paths, so no friend request)
create or replace function public.how_we_met(p_x uuid, p_y uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    -- a match you've actually talked to (the call-first rule still holds)
    (select 'You matched and talked' from matches m
      where least(m.user_a, m.user_b) = least(p_x, p_y) and greatest(m.user_a, m.user_b) = greatest(p_x, p_y)
        and m.call_done and coalesce(m.end_reason, '') <> 'report' limit 1),
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
-- Requests
-- ---------------------------------------------------------------------
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
      'inner', case when f.user_a = me then f.a_inner else f.b_inner end,   -- I put them in my inner circle
      'their_inner', in_inner_circle(p_user, me));                          -- they put me in theirs
  elsif f.status = 'pending' then
    return jsonb_build_object('status', case when f.requested_by = me then 'outgoing' else 'incoming' end);
  end if;
  v_met := how_we_met(me, p_user);
  -- a declined request looks the same as "sent" to the person who asked, for 30 days
  if f.status = 'declined' and f.requested_by = me and f.responded_at > now() - interval '30 days' then
    return jsonb_build_object('status', 'outgoing');
  end if;
  return jsonb_build_object('status', case when v_met is null then 'unavailable' else 'none' end, 'met', v_met);
end $$;

create or replace function public.request_friend(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f friendships;
begin
  if me is null or p_user is null or p_user = me then raise exception 'Not allowed.'; end if;
  if (select status from profiles where id = me) <> 'active'
     or coalesce((select status from profiles where id = p_user), '') <> 'active' then
    raise exception 'That person isn''t available right now.';
  end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    raise exception 'That person isn''t available right now.';
  end if;

  f := friendship_between(me, p_user);
  if f.status = 'accepted' then return 'friends'; end if;
  if f.status = 'pending' and f.requested_by = me then return 'outgoing'; end if;
  if f.status = 'pending' then  -- they already asked you: this accepts it
    return respond_friend(p_user, true);
  end if;
  if f.status = 'declined' and f.requested_by = me and f.responded_at > now() - interval '30 days' then
    return 'outgoing';  -- quietly; no repeat notification
  end if;

  if how_we_met(me, p_user) is null then
    raise exception 'You can add people you''ve talked to, or met in a circle or at an event.';
  end if;
  if (select count(*) from friendships where requested_by = me and created_at > now() - interval '1 day') >= 20 then
    raise exception 'That''s a lot of requests today. Try again tomorrow.';
  end if;

  insert into friendships (user_a, user_b, requested_by, status, created_at, responded_at, a_inner, b_inner)
  values (least(me, p_user), greatest(me, p_user), me, 'pending', now(), null, false, false)
  on conflict (user_a, user_b) do update
    set requested_by = me, status = 'pending', created_at = now(), responded_at = null, a_inner = false, b_inner = false;

  perform notify(p_user, 'friend_request',
    (select display_name from profiles where id = me) || ' wants to add you as a friend.');
  return 'outgoing';
end $$;

create or replace function public.respond_friend(p_user uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f friendships;
begin
  f := friendship_between(me, p_user);
  if f.id is null or f.status <> 'pending' or f.requested_by = me then raise exception 'No request to answer.'; end if;
  if p_accept then
    update friendships set status = 'accepted', responded_at = now() where id = f.id;
    perform notify(p_user, 'friend_accepted',
      (select display_name from profiles where id = me) || ' accepted your friend request.');
    return 'friends';
  end if;
  update friendships set status = 'declined', responded_at = now() where id = f.id;  -- no notice to them
  return 'none';
end $$;

-- Unfriend, or cancel a request you sent. Messages go with it.
create or replace function public.remove_friend(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  delete from friendships
  where user_a = least(me, p_user) and user_b = greatest(me, p_user)
    and (status = 'accepted' or (status = 'pending' and requested_by = me));
end $$;

create or replace function public.set_inner_circle(p_user uuid, p_inner boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  f friendships;
begin
  f := friendship_between(me, p_user);
  if f.id is null or f.status <> 'accepted' then raise exception 'Only friends can be in your inner circle.'; end if;
  if f.user_a = me then
    update friendships set a_inner = coalesce(p_inner, false) where id = f.id;
  else
    update friendships set b_inner = coalesce(p_inner, false) where id = f.id;
  end if;
end $$;

create or replace function public.set_friend_visibility(p_plans boolean, p_circles boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set friend_visibility = jsonb_build_object('plans', coalesce(p_plans, false), 'circles', coalesce(p_circles, false))
  where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------
-- What a friend's card shows me, given what they let me see
create or replace function public.friend_card_extras(p_friend uuid, p_viewer uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  vis jsonb := coalesce((select friend_visibility from profiles where id = p_friend), '{}');
  inner_ok boolean := in_inner_circle(p_friend, p_viewer);
  see_plans boolean := inner_ok or coalesce((vis ->> 'plans')::boolean, false);
  see_circles boolean := inner_ok or coalesce((vis ->> 'circles')::boolean, false);
begin
  return jsonb_build_object(
    'plans', case when not see_plans then null else (
      select coalesce(jsonb_agg(jsonb_build_object('title', x.title, 'starts_at', x.starts_at, 'place', x.place_name) order by x.starts_at), '[]')
      from (select e.title, e.starts_at, e.place_name from event_rsvps r join events e on e.id = r.event_id
            where r.user_id = p_friend and r.status = 'going' and e.status = 'active'
              and e.starts_at between now() - interval '3 hours' and now() + interval '30 days'
              and (e.circle_id is null or exists (select 1 from circle_members cm where cm.circle_id = e.circle_id and cm.user_id = p_viewer))
            order by e.starts_at limit 3) x) end,
    'circles', case when not see_circles then null else (
      select coalesce(jsonb_agg(c.name order by c.name), '[]')
      from circle_members cm join circles c on c.id = cm.circle_id where cm.user_id = p_friend) end);
end $$;

create or replace function public.get_friends()
returns table (user_id uuid, name text, photo text, friendship_id uuid, since timestamptz,
               is_inner boolean, their_inner boolean, plans jsonb, circles jsonb,
               last_message text, last_from_me boolean, last_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Please log in again.'; end if;
  return query
  with mine as (
    select f.*, case when f.user_a = me then f.user_b else f.user_a end as other,
           case when f.user_a = me then f.a_inner else f.b_inner end as my_inner
    from friendships f
    where f.status = 'accepted' and me in (f.user_a, f.user_b)
  )
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         m.id, m.responded_at, m.my_inner, in_inner_circle(p.id, me),
         x.extras -> 'plans', x.extras -> 'circles',
         lm.body, lm.sender_id = me, lm.created_at
  from mine m
  join profiles p on p.id = m.other and p.status = 'active'
  cross join lateral (select friend_card_extras(p.id, me) as extras) x
  left join lateral (select fm.body, fm.sender_id, fm.created_at from friend_messages fm
                     where fm.friendship_id = m.id order by fm.created_at desc limit 1) lm on true
  where not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
  order by m.my_inner desc, coalesce(lm.created_at, m.responded_at) desc;
end $$;

create or replace function public.get_friend_requests()
returns table (user_id uuid, name text, photo text, met text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return query
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         how_we_met(me, p.id), f.created_at
  from friendships f
  join profiles p on p.id = f.requested_by and p.status = 'active'
  where f.status = 'pending' and f.requested_by <> me and me in (f.user_a, f.user_b)
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
  order by f.created_at desc;
end $$;

-- People going to an event (only for people who are going or maybe themselves), so you can find who you met
create or replace function public.get_event_people(p_event uuid)
returns table (user_id uuid, name text, photo text, rsvp text)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if not exists (select 1 from event_rsvps where event_id = p_event and user_id = me) then
    raise exception 'RSVP to see who''s going.';
  end if;
  return query
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         r.status
  from event_rsvps r join profiles p on p.id = r.user_id and p.status = 'active'
  where r.event_id = p_event
    and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
  order by (r.user_id = me) desc, r.status, p.display_name;
end $$;

-- ---------------------------------------------------------------------
-- Messages between friends (no call-first rule; they've already met)
-- ---------------------------------------------------------------------
drop policy if exists "friend messages read" on public.friend_messages;
create policy "friend messages read" on public.friend_messages for select to authenticated
  using (public.is_friend_thread(friendship_id));
drop policy if exists "friend messages send" on public.friend_messages;
create policy "friend messages send" on public.friend_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_friend_thread(friendship_id));

create or replace function public.tg_friend_message_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  f friendships;
begin
  select * into f from friendships where id = new.friendship_id;
  perform send_push(case when f.user_a = new.sender_id then f.user_b else f.user_a end,
    (select display_name from profiles where id = new.sender_id),
    left(new.body, 120),
    jsonb_build_object('kind', 'friend_message', 'friendship_id', new.friendship_id));
  update profiles set last_active_at = now() where id = new.sender_id;
  return null;
end $$;

drop trigger if exists friend_message_push on public.friend_messages;
create trigger friend_message_push after insert on public.friend_messages
for each row execute function public.tg_friend_message_push();

-- Blocking someone ends the friendship
create or replace function public.tg_block_unfriend()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from friendships where user_a = least(new.blocker, new.blocked) and user_b = greatest(new.blocker, new.blocked);
  return null;
end $$;

drop trigger if exists block_unfriend on public.blocks;
create trigger block_unfriend after insert on public.blocks
for each row execute function public.tg_block_unfriend();

-- Push titles for the new notices
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
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'friend_messages') then
    alter publication supabase_realtime add table public.friend_messages;
  end if;
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.friend_status(uuid)', 'public.request_friend(uuid)', 'public.respond_friend(uuid,boolean)',
    'public.remove_friend(uuid)', 'public.set_inner_circle(uuid,boolean)', 'public.set_friend_visibility(boolean,boolean)',
    'public.get_friends()', 'public.get_friend_requests()', 'public.get_event_people(uuid)',
    'public.is_friend_thread(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.friendship_between(uuid,uuid)', 'public.in_inner_circle(uuid,uuid)', 'public.how_we_met(uuid,uuid)',
    'public.friend_card_extras(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
