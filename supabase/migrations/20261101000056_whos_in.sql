-- Who's In (Nov 1 2026, from the Oct 27 vision doc): every plan becomes something that actually happens.
--  * "I'm in" is the Going RSVP. Each plan gets a plan page with:
--      - What we need: gear, rides, food ("Truck", "Boat", "Tent", "Ride from the NW"). Anyone in can add
--        an item; anyone going can claim it ("I'll bring it").
--      - A group chat for the people in (going or maybe) and the host.
--      - A reminder 2-3 hours before it starts, to everyone going.
--      - Afterwards, everyone who went is asked "Did it happen?". Once 2 people confirm, it's marked as
--        happened (that feeds the real-world tally).
--  * Photos after the plan are not in this version.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.event_needs (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  item       text not null check (char_length(item) between 1 and 40),
  added_by   uuid references public.profiles(id) on delete set null,
  claimed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists event_needs_event on public.event_needs (event_id, created_at);

create table if not exists public.event_messages (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events(id) on delete cascade,
  sender_id  uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists event_messages_event on public.event_messages (event_id, created_at);

create table if not exists public.event_happened (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  happened   boolean not null,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table if not exists public.event_pings (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id  uuid not null references public.profiles(id) on delete cascade,
  kind     text not null check (kind in ('soon','ask')),
  primary key (event_id, user_id, kind)
);

alter table public.event_needs    enable row level security;
alter table public.event_messages enable row level security;
alter table public.event_happened enable row level security;
alter table public.event_pings    enable row level security;

-- ---------------------------------------------------------------------
-- Who's in a plan (host, going or maybe)
-- ---------------------------------------------------------------------
create or replace function public.in_plan(p_event uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from events e where e.id = p_event and e.creator_id = p_user)
      or exists (select 1 from event_rsvps r where r.event_id = p_event and r.user_id = p_user);
$$;

-- Plan chat: read and write only if you're in
drop policy if exists "plan chat read" on public.event_messages;
create policy "plan chat read" on public.event_messages for select to authenticated
  using (public.is_tester() and public.in_plan(event_id));
drop policy if exists "plan chat send" on public.event_messages;
create policy "plan chat send" on public.event_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_tester() and public.in_plan(event_id));

create or replace function public.tg_event_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.body := btrim(new.body);
  if char_length(new.body) = 0 then raise exception 'Say something.'; end if;
  if blocked_term_in(new.body) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
  if (select count(*) from event_messages where sender_id = new.sender_id and created_at > now() - interval '1 minute') >= 20 then
    raise exception 'Slow down a little.';
  end if;
  return new;
end $$;
drop trigger if exists event_message_before on public.event_messages;
create trigger event_message_before before insert on public.event_messages
for each row execute function public.tg_event_message_before();

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'event_messages') then
    alter publication supabase_realtime add table public.event_messages;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- The plan page
-- ---------------------------------------------------------------------
create or replace function public.get_plan(p_event uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  e events;
  v_in boolean;
begin
  select * into e from events where id = p_event;
  if e.id is null or not can_see_event(p_event, me) then raise exception 'That plan is gone.'; end if;
  v_in := in_plan(p_event, me);
  return jsonb_build_object(
    'event_id', e.id,
    'title', e.title,
    'starts_at', e.starts_at,
    'host', (select display_name from profiles where id = e.creator_id),
    'mine', e.creator_id = me,
    'my_rsvp', (select status from event_rsvps where event_id = e.id and user_id = me),
    'in', v_in,
    'started', e.starts_at <= now(),
    'needs', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', n.id, 'item', n.item,
                'claimed_by', (select display_name from profiles where id = n.claimed_by),
                'mine', coalesce(n.claimed_by = me, false),
                'can_remove', n.added_by = me or e.creator_id = me)
              order by n.created_at), '[]'::jsonb)
              from event_needs n where n.event_id = e.id),
    -- who's in, only once you're in (same rule as the people list)
    'people', case when v_in then (
                select coalesce(jsonb_agg(jsonb_build_object(
                  'user_id', p.id, 'name', p.display_name, 'rsvp', coalesce(r.status, 'host'),
                  'photo', (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'))
                  order by (p.id = e.creator_id) desc, r.created_at), '[]'::jsonb)
                from profiles p left join event_rsvps r on r.event_id = e.id and r.user_id = p.id
                where p.status = 'active' and (p.id = e.creator_id or r.user_id is not null))
              else '[]'::jsonb end,
    'my_happened', (select happened from event_happened where event_id = e.id and user_id = me),
    'happened', (select count(*) from event_happened where event_id = e.id and happened) >= 2
  );
end $$;

create or replace function public.add_plan_need(p_event uuid, p_item text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v text := left(btrim(regexp_replace(coalesce(p_item, ''), '\s+', ' ', 'g')), 40);
begin
  if not in_plan(p_event, me) then raise exception 'Tap I''m in first.'; end if;
  if char_length(v) = 0 then raise exception 'What''s needed?'; end if;
  if blocked_term_in(v) is not null or cardinality(detect_contact(v)) > 0 then raise exception 'That wording isn''t allowed.'; end if;
  if (select count(*) from event_needs where event_id = p_event) >= 12 then raise exception 'That''s 12 things already.'; end if;
  insert into event_needs (event_id, item, added_by) values (p_event, v, me);
end $$;

create or replace function public.remove_plan_need(p_need uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  delete from event_needs n using events e
  where n.id = p_need and e.id = n.event_id and (n.added_by = me or e.creator_id = me);
  if not found then raise exception 'Only whoever added it, or the host, can take it off.'; end if;
end $$;

-- "I'll bring it" (or take it back)
create or replace function public.claim_plan_need(p_need uuid, p_claim boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  n event_needs;
begin
  select * into n from event_needs where id = p_need;
  if n.id is null then raise exception 'That''s gone.'; end if;
  if not exists (select 1 from event_rsvps where event_id = n.event_id and user_id = me and status = 'going')
     and not exists (select 1 from events where id = n.event_id and creator_id = me) then
    raise exception 'Tap I''m in first.';
  end if;
  if p_claim then
    update event_needs set claimed_by = me where id = n.id and claimed_by is null;
    if not found then raise exception 'Someone already has that covered.'; end if;
  else
    update event_needs set claimed_by = null where id = n.id and claimed_by = me;
  end if;
end $$;

-- After it starts: did it actually happen?
create or replace function public.confirm_plan_happened(p_event uuid, p_happened boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  e events;
begin
  select * into e from events where id = p_event;
  if e.id is null then raise exception 'That plan is gone.'; end if;
  if e.starts_at > now() then raise exception 'Ask again after it starts.'; end if;
  if e.creator_id <> me and not exists (select 1 from event_rsvps where event_id = e.id and user_id = me and status = 'going') then
    raise exception 'Only people who said I''m in can confirm.';
  end if;
  insert into event_happened (event_id, user_id, happened) values (e.id, me, p_happened)
  on conflict (event_id, user_id) do update set happened = excluded.happened, created_at = now();
end $$;

-- ---------------------------------------------------------------------
-- Reminders (every 15 minutes)
-- ---------------------------------------------------------------------
create or replace function public.ping_plans()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  -- 2-3 hours before: everyone going and the host
  for r in
    select e.id, e.title, e.starts_at, x.user_id
    from events e
    join lateral (select rv.user_id from event_rsvps rv where rv.event_id = e.id and rv.status = 'going'
                  union select e.creator_id) x on true
    where e.status = 'active' and e.starts_at between now() + interval '2 hours' and now() + interval '3 hours'
      and not exists (select 1 from event_pings p where p.event_id = e.id and p.user_id = x.user_id and p.kind = 'soon')
  loop
    insert into event_pings (event_id, user_id, kind) values (r.id, r.user_id, 'soon') on conflict do nothing;
    perform notify(r.user_id, 'plan',
      '"' || left(r.title, 50) || '" starts at ' ||
      ltrim(to_char(r.starts_at at time zone 'America/Edmonton', 'HH12:MI AM'), '0') ||
      '. Check the plan page for who''s bringing what.');
    n := n + 1;
  end loop;

  -- 3-24 hours after it started: did it happen?
  for r in
    select e.id, e.title, x.user_id
    from events e
    join lateral (select rv.user_id from event_rsvps rv where rv.event_id = e.id and rv.status = 'going'
                  union select e.creator_id) x on true
    where e.status = 'active' and e.starts_at between now() - interval '24 hours' and now() - interval '3 hours'
      and not exists (select 1 from event_pings p where p.event_id = e.id and p.user_id = x.user_id and p.kind = 'ask')
      and not exists (select 1 from event_happened h where h.event_id = e.id and h.user_id = x.user_id)
  loop
    insert into event_pings (event_id, user_id, kind) values (r.id, r.user_id, 'ask') on conflict do nothing;
    perform notify(r.user_id, 'plan', 'Did "' || left(r.title, 50) || '" happen? Confirm it on the plan page.');
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'ping-plans') then perform cron.unschedule('ping-plans'); end if;
  perform cron.schedule('ping-plans', '*/15 * * * *', 'select public.ping_plans()');
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_plan(uuid)', 'public.add_plan_need(uuid,text)', 'public.remove_plan_need(uuid)',
    'public.claim_plan_need(uuid,boolean)', 'public.confirm_plan_happened(uuid,boolean)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- in_plan is used by the chat policies, so signed-in members can call it
  execute 'revoke all on function public.in_plan(uuid,uuid) from public, anon';
  execute 'grant execute on function public.in_plan(uuid,uuid) to authenticated';
  execute 'revoke all on function public.ping_plans() from public, anon, authenticated';
end $$;
