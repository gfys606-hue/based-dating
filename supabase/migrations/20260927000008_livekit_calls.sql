-- Real in-app calls via LiveKit.
--   call-token      (edge function): checks the caller may join, returns a LiveKit room token
--   livekit-webhook (edge function): LiveKit reports joins/leaves; these functions track them
--                                    and, when the room closes, apply the call rules via complete_call().
-- The call "clock" starts only when BOTH people are in the room, and stops when the first one leaves.

alter table public.calls
  add column if not exists joined_users    uuid[] not null default '{}',
  add column if not exists both_joined_at  timestamptz,
  add column if not exists first_left_at   timestamptz,
  add column if not exists first_left_by   uuid,
  add column if not exists first_left_drop boolean not null default false; -- true = connection dropped

-- Can this user join this call right now? Used by the call-token function.
create or replace function public.can_join_call(p_call uuid, p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  c calls;
  m matches;
begin
  select * into c from calls where id = p_call;
  if c.id is null then return 'No such call'; end if;
  select * into m from matches where id = c.match_id;
  if p_user not in (m.user_a, m.user_b) then return 'Not your call'; end if;
  if m.status <> 'active' then return 'This match has ended'; end if;
  if c.status <> 'accepted' then return 'This call isn''t open'; end if;
  if now() < c.scheduled_for - interval '15 minutes' then return 'Too early: you can join 15 minutes before the call'; end if;
  if now() > c.scheduled_for + interval '3 hours' then return 'This call time has passed'; end if;
  return 'ok';
end $$;

-- LiveKit participant_joined / participant_left
create or replace function public.livekit_participant(p_call uuid, p_user uuid, p_joined boolean, p_drop boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare c calls;
begin
  select * into c from calls where id = p_call for update;
  if c.id is null or c.status in ('completed','short','cancelled','missed') then return; end if;

  if p_joined then
    if not (p_user = any(c.joined_users)) then
      update calls set joined_users = array_append(joined_users, p_user) where id = p_call
      returning * into c;
    end if;
    if c.both_joined_at is null and cardinality(c.joined_users) >= 2 then
      update calls set both_joined_at = now(), started_at = now() where id = p_call;
    end if;
  else
    if c.both_joined_at is not null and c.first_left_at is null then
      update calls set first_left_at = now(), first_left_by = p_user, first_left_drop = p_drop where id = p_call;
    end if;
  end if;
end $$;

-- LiveKit room_finished: score the call once.
create or replace function public.livekit_room_finished(p_call uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  c calls;
  v_secs int;
  v_reason text;
begin
  select * into c from calls where id = p_call for update;
  if c.id is null or c.status in ('completed','short','cancelled','missed') then return 'ignored'; end if;
  if c.both_joined_at is null then return 'never_connected'; end if; -- no-show rules handle this

  v_secs := greatest(0, extract(epoch from coalesce(c.first_left_at, now()) - c.both_joined_at))::int;

  if c.first_left_drop then
    v_reason := 'connection';
  elsif exists (select 1 from reports r
                where r.reporter_id = c.first_left_by and r.match_id = c.match_id
                  and r.created_at >= c.both_joined_at - interval '1 minute') then
    v_reason := 'report';
  else
    v_reason := 'early';
  end if;

  return complete_call(c.id, c.kind, v_secs, c.first_left_by, v_reason);
end $$;

revoke all on function public.can_join_call(uuid, uuid) from public, anon, authenticated;
revoke all on function public.livekit_participant(uuid, uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public.livekit_room_finished(uuid) from public, anon, authenticated;
