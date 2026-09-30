-- Push notifications (Android, via Firebase Cloud Messaging).
--   * the app registers its device token in push_tokens
--   * every new row in notifications, and every new chat message, calls the `push` edge function
--     (through pg_net, so it never slows down or blocks the app)
--   * a reminder goes out 15 minutes before each confirmed call
-- Nothing is sent until the `push` function is deployed and FIREBASE_SERVICE_ACCOUNT is set.

create extension if not exists pg_net with schema extensions;

-- Private settings the database uses to call the push function. Generated here; nobody has to copy secrets around.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);
insert into private.settings values ('push_secret', encode(gen_random_bytes(24), 'hex')) on conflict do nothing;
insert into private.settings values ('push_url', 'https://dzfnetcoyxjyjtmorfgk.supabase.co/functions/v1/push') on conflict do nothing;

-- Device tokens
create table if not exists public.push_tokens (
  token      text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  platform   text not null default 'android',
  updated_at timestamptz not null default now()
);
create index if not exists push_tokens_user on public.push_tokens (user_id);
alter table public.push_tokens enable row level security; -- no direct client access; use the functions below

create or replace function public.register_push_token(p_token text, p_platform text default 'android')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(p_token, '') = '' then return; end if;
  insert into push_tokens (token, user_id, platform) values (p_token, auth.uid(), p_platform)
  on conflict (token) do update set user_id = auth.uid(), platform = excluded.platform, updated_at = now();
end $$;

create or replace function public.unregister_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from push_tokens where token = p_token and user_id = auth.uid();
$$;

-- The push function calls this to check the request really came from our database.
create or replace function public.push_secret_ok(p_secret text)
returns boolean language sql stable security definer set search_path = public, private as $$
  select exists (select 1 from private.settings where key = 'push_secret' and value = p_secret);
$$;

-- Queue one push (fire-and-forget). Skips people with no registered device.
create or replace function public.send_push(p_user uuid, p_title text, p_body text, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = public, private, extensions as $$
begin
  if not exists (select 1 from push_tokens where user_id = p_user) then return; end if;
  perform net.http_post(
    url     := (select value from private.settings where key = 'push_url'),
    body    := jsonb_build_object('user_id', p_user, 'title', p_title, 'body', p_body, 'data', coalesce(p_data, '{}'::jsonb)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-push-secret', (select value from private.settings where key = 'push_secret')));
exception when others then
  null; -- a push problem must never break matching, messaging or calls
end $$;

-- Every app notice also goes out as a push
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
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;

drop trigger if exists notification_push on public.notifications;
create trigger notification_push after insert on public.notifications
for each row execute function public.tg_notification_push();

-- New chat message -> push to the other person (not added to the in-app notices list)
create or replace function public.tg_message_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m matches;
  v_to uuid;
begin
  if new.status <> 'sent' then return null; end if;
  select * into m from matches where id = new.match_id;
  v_to := case when m.user_a = new.sender_id then m.user_b else m.user_a end;
  perform send_push(v_to,
    (select display_name from profiles where id = new.sender_id),
    left(new.body, 120),
    jsonb_build_object('kind', 'message', 'match_id', new.match_id));
  return null;
end $$;

drop trigger if exists message_push on public.messages;
create trigger message_push after insert on public.messages
for each row execute function public.tg_message_push();

-- 15-minute call reminders
alter table public.calls add column if not exists reminded boolean not null default false;

create or replace function public.remind_upcoming_calls()
returns int language plpgsql security definer set search_path = public as $$
declare
  c record;
  n int := 0;
begin
  for c in select cl.id, cl.kind, cl.scheduled_for, m.user_a, m.user_b
           from calls cl join matches m on m.id = cl.match_id
           where cl.status = 'accepted' and not cl.reminded and m.status = 'active'
             and cl.scheduled_for between now() and now() + interval '15 minutes'
           for update of cl skip locked loop
    update calls set reminded = true where id = c.id;
    perform notify(c.user_a, 'call_soon', format('Your %s call with %s starts in %s minutes.', c.kind,
      (select display_name from profiles where id = c.user_b), greatest(1, ceil(extract(epoch from c.scheduled_for - now()) / 60))::int));
    perform notify(c.user_b, 'call_soon', format('Your %s call with %s starts in %s minutes.', c.kind,
      (select display_name from profiles where id = c.user_a), greatest(1, ceil(extract(epoch from c.scheduled_for - now()) / 60))::int));
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.push_secret_ok(text) from public, anon, authenticated;
grant execute on function public.push_secret_ok(text) to service_role;
revoke all on function public.send_push(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.remind_upcoming_calls() from public, anon, authenticated;
revoke all on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;
revoke all on function public.unregister_push_token(text) from public, anon;
grant execute on function public.unregister_push_token(text) to authenticated;

select cron.schedule('remind-upcoming-calls', '*/5 * * * *', $$select public.remind_upcoming_calls()$$);
