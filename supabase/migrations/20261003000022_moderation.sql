-- Safety review: reports and photo checks land in one admin queue with actions.
--  * Reports can now come from anywhere (profiles, circles, events), not just chat.
--  * You see each reported person once, with every report, the chat around a match report,
--    and their history; then dismiss, warn, suspend, ban or reinstate. Every action is logged.
--  * Photo checks (when AI checks are off) can be approved or rejected right in the app.

alter table public.reports drop constraint if exists reports_category_check;
alter table public.reports add constraint reports_category_check
  check (category in ('fake_profile','harassment','scam','explicit','underage','threats','spam','other'));
alter table public.reports add column if not exists context text check (char_length(context) <= 40);  -- where it came from

create table if not exists public.moderation_actions (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  action     text not null check (action in ('dismiss','warn','suspend','ban','reinstate','photo_ok','photo_reject')),
  note       text check (char_length(note) <= 500),
  admin_id   uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.moderation_actions enable row level security;  -- functions only

-- Admins can look at selfies for photo checks
drop policy if exists "admin selfie read" on storage.objects;
create policy "admin selfie read" on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and public.is_admin());

-- Report from anywhere (same protections as before: block, end the match, auto-suspend on a pattern)
create or replace function public.report_user(p_target uuid, p_category text, p_details text default null,
                                              p_match uuid default null, p_context text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_reporters int;
begin
  if me is null or p_target = me then raise exception 'Not allowed.'; end if;
  if (select count(*) from reports where reporter_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Too many reports today. We''re looking at the ones you sent.';
  end if;
  insert into reports (reporter_id, reported_id, match_id, category, details, priority, context)
  values (me, p_target, p_match, p_category, left(p_details, 1000), p_category in ('underage','threats'), left(p_context, 40));

  insert into blocks (blocker, blocked) values (me, p_target) on conflict do nothing;
  update matches set status = 'ended', ended_by = me, end_reason = 'report', ended_at = now()
  where user_a = least(me, p_target) and user_b = greatest(me, p_target) and status = 'active';

  select count(distinct reporter_id) into v_reporters
  from reports where reported_id = p_target and created_at > now() - interval '30 days';

  if v_reporters >= 3 or p_category in ('underage','threats') and v_reporters >= 2 then
    update profiles set status = 'suspended', pause_reason = 'Under review' where id = p_target and status = 'active';
  end if;
end $$;
drop function if exists public.report_user(uuid, text, text, uuid);

-- ---------------------------------------------------------------------
-- The queue
-- ---------------------------------------------------------------------
create or replace function public.admin_queue_counts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return jsonb_build_object(
    'reports', (select count(distinct reported_id) from reports where status = 'open'),
    'urgent', (select count(distinct reported_id) from reports where status = 'open' and priority),
    'photos', (select count(*) from manual_review where not checked),
    'bars', 0);
end $$;

-- One row per reported person with open reports, most urgent first
create or replace function public.admin_reports()
returns table (user_id uuid, name text, photo text, status text, open_reports int, reporters int,
               categories text[], urgent boolean, latest timestamptz, past_actions int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1),
         p.status,
         count(*)::int, count(distinct r.reporter_id)::int,
         array_agg(distinct r.category), bool_or(r.priority), max(r.created_at),
         (select count(*)::int from moderation_actions a where a.user_id = p.id and a.action in ('warn','suspend','ban'))
  from reports r join profiles p on p.id = r.reported_id
  where r.status = 'open'
  group by p.id
  order by bool_or(r.priority) desc, count(distinct r.reporter_id) desc, max(r.created_at) desc;
end $$;

-- Everything needed to decide: all reports, the chat around match reports, and past actions
create or replace function public.admin_report_detail(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare p profiles;
begin
  perform require_admin();
  select * into p from profiles where id = p_user;
  return jsonb_build_object(
    'user', jsonb_build_object('id', p.id, 'name', p.display_name, 'status', p.status, 'pause_reason', p.pause_reason,
                               'joined', p.created_at, 'last_active', p.last_active_at,
                               'invited_by', (select pr.display_name from invite_redemptions r join profiles pr on pr.id = r.inviter_id where r.user_id = p.id),
                               'joined_via', (select source_label from invite_redemptions where user_id = p.id)),
    'reports', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', r.id, 'category', r.category, 'details', r.details, 'status', r.status, 'context', r.context,
                   'reporter', (select display_name from profiles where id = r.reporter_id),
                   'created_at', r.created_at,
                   'messages', case when r.match_id is null then null else (
                      select coalesce(jsonb_agg(jsonb_build_object('from', pr.display_name, 'body', m.body, 'at', m.created_at,
                                                                   'status', m.status) order by m.created_at), '[]')
                      from (select * from messages where match_id = r.match_id order by created_at desc limit 30) m
                      join profiles pr on pr.id = m.sender_id) end)
                 order by r.created_at desc), '[]')
                from reports r where r.reported_id = p_user),
    'actions', (select coalesce(jsonb_agg(jsonb_build_object('action', a.action, 'note', a.note, 'at', a.created_at,
                                                             'by', (select display_name from profiles where id = a.admin_id))
                                          order by a.created_at desc), '[]')
                from moderation_actions a where a.user_id = p_user));
end $$;

-- dismiss | warn | suspend | ban | reinstate
create or replace function public.admin_moderate(p_user uuid, p_action text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_admin();
begin
  if p_action not in ('dismiss','warn','suspend','ban','reinstate') then raise exception 'Unknown action.'; end if;
  if p_user = me then raise exception 'Not on yourself.'; end if;

  if p_action = 'dismiss' then
    update reports set status = 'dismissed' where reported_id = p_user and status = 'open';
    update profiles set status = 'active', pause_reason = null
     where id = p_user and status = 'suspended' and pause_reason = 'Under review';
  elsif p_action = 'warn' then
    update reports set status = 'actioned' where reported_id = p_user and status = 'open';
    update profiles set status = 'active', pause_reason = null
     where id = p_user and status = 'suspended' and pause_reason = 'Under review';
    perform notify(p_user, 'warning', coalesce(nullif(btrim(p_note), ''),
      'Members reported how you''ve been treating people. Keep it respectful or your account will be suspended.'));
  elsif p_action = 'suspend' then
    update reports set status = 'actioned' where reported_id = p_user and status = 'open';
    update profiles set status = 'suspended', pause_reason = coalesce(nullif(btrim(p_note), ''), 'Suspended after reports') where id = p_user;
    update matches set status = 'ended', end_reason = 'report', ended_at = now() where p_user in (user_a, user_b) and status = 'active';
  elsif p_action = 'ban' then
    update reports set status = 'actioned' where reported_id = p_user and status = 'open';
    perform ban_user(p_user);
    delete from circle_members where user_id = p_user;
    delete from friendships where p_user in (user_a, user_b);
    delete from checkins where user_id = p_user;
  elsif p_action = 'reinstate' then
    update profiles set status = 'active', pause_reason = null where id = p_user and status in ('suspended','banned');
  end if;

  insert into moderation_actions (user_id, action, note, admin_id) values (p_user, p_action, left(p_note, 500), me);
end $$;

-- ---------------------------------------------------------------------
-- Photo checks
-- ---------------------------------------------------------------------
create or replace function public.admin_photo_queue()
returns table (review_id bigint, user_id uuid, name text, kind text, path text, bucket text, photo_position int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select m.id, p.id, p.display_name, m.kind,
         case when m.kind = 'selfie' then p.selfie_path else ph.storage_path end,
         case when m.kind = 'selfie' then 'selfies' else 'photos' end,
         ph.position, m.created_at
  from manual_review m join profiles p on p.id = m.user_id left join photos ph on ph.id = m.photo_id
  where not m.checked
  order by m.created_at
  limit 60;
end $$;

create or replace function public.admin_photo_decision(p_review bigint, p_ok boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  m manual_review;
begin
  select * into m from manual_review where id = p_review;
  if m.id is null then return; end if;
  update manual_review set checked = true where id = p_review;
  if p_ok then
    if m.photo_id is not null then update photos set review_status = 'approved' where id = m.photo_id; end if;
  else
    if m.photo_id is not null then
      update photos set review_status = 'rejected' where id = m.photo_id;
    elsif m.kind = 'selfie' then
      update profiles set selfie_verified = false where id = m.user_id;
      perform notify(m.user_id, 'paused', coalesce(nullif(btrim(p_note), ''), 'Your selfie didn''t match your photos. Take a new one to continue.'));
    end if;
    perform refresh_photo_status(m.user_id);
  end if;
  insert into moderation_actions (user_id, action, note, admin_id)
  values (m.user_id, case when p_ok then 'photo_ok' else 'photo_reject' end, left(p_note, 500), me);
end $$;

-- Push title for the warning notice
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
      when 'circle_invite'    then 'Circle invite'
      when 'circle_vote'      then 'New nomination'
      when 'circle_joined'    then 'New member'
      when 'warning'          then 'A note from Based'
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
    'public.report_user(uuid,text,text,uuid,text)', 'public.admin_queue_counts()', 'public.admin_reports()',
    'public.admin_report_detail(uuid)', 'public.admin_moderate(uuid,text,text)', 'public.admin_photo_queue()',
    'public.admin_photo_decision(bigint,boolean,text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

