-- Venue owners, barring, and table requests.
--  * A venue is a place (from the map) with staff. Owners/managers apply in the app; the admin approves.
--  * Staff can ask to bar someone. The admin reviews every request. First approved bar = 30 days,
--    the next one at the same venue = indefinite. While barred, the person can't see or RSVP to that
--    venue's plans or check in there. They're told, and they can appeal.
--  * Bars from 3 unrelated venues (different owners) in the last 12 months put a mark on the profile.
--    Lifted bars and bars older than 12 months don't count.
--  * Phase 2 reservations: a plan pinned to a partner venue can ask for a table; staff approve,
--    approve fewer people, or decline.

create table if not exists public.venues (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null unique references public.places(id) on delete cascade,
  owner_group uuid,                       -- the owner's account: venues with the same owner are "related"
  capacity    int check (capacity is null or capacity between 2 and 1000),
  created_at  timestamptz not null default now()
);

create table if not exists public.venue_staff (
  venue_id   uuid references public.venues(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  role       text not null check (role in ('owner','manager')),
  created_at timestamptz not null default now(),
  primary key (venue_id, user_id)
);

create table if not exists public.venue_applications (
  id          bigserial primary key,
  place_id    uuid not null references public.places(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  role        text not null check (role in ('owner','manager')),
  note        text check (char_length(note) <= 500),
  status      text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);

create table if not exists public.venue_bars (
  id           uuid primary key default gen_random_uuid(),
  venue_id     uuid not null references public.venues(id) on delete cascade,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  requested_by uuid references public.profiles(id) on delete set null,
  reason       text not null check (char_length(reason) between 5 and 1000),
  length       text not null check (length in ('30_days','indefinite')),
  status       text not null default 'pending' check (status in ('pending','approved','declined','lifted')),
  appeal       text check (char_length(appeal) <= 1000),
  appealed_at  timestamptz,
  admin_note   text check (char_length(admin_note) <= 500),
  starts_at    timestamptz,
  ends_at      timestamptz,            -- null = indefinite
  created_at   timestamptz not null default now(),
  decided_at   timestamptz
);
create index if not exists venue_bars_user on public.venue_bars (user_id, status);

create table if not exists public.table_requests (
  id            uuid primary key default gen_random_uuid(),
  venue_id      uuid not null references public.venues(id) on delete cascade,
  event_id      uuid references public.events(id) on delete cascade,
  requested_by  uuid not null references public.profiles(id) on delete cascade,
  party_size    int not null check (party_size between 1 and 200),
  starts_at     timestamptz not null,
  note          text check (char_length(note) <= 300),
  status        text not null default 'pending' check (status in ('pending','approved','partial','declined','cancelled')),
  approved_size int,
  staff_note    text check (char_length(staff_note) <= 300),
  decided_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  decided_at    timestamptz
);
create unique index if not exists table_requests_one_per_event on public.table_requests (event_id) where status in ('pending','approved','partial');

alter table public.venues             enable row level security;  -- functions only
alter table public.venue_staff        enable row level security;
alter table public.venue_applications enable row level security;
alter table public.venue_bars         enable row level security;
alter table public.table_requests     enable row level security;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.venue_of(p_place uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from venues where place_id = p_place;
$$;

create or replace function public.is_venue_staff(p_venue uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from venue_staff where venue_id = p_venue and user_id = p_user);
$$;

create or replace function public.is_barred(p_user uuid, p_place uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_place is not null and exists (
    select 1 from venue_bars b join venues v on v.id = b.venue_id
    where v.place_id = p_place and b.user_id = p_user and b.status = 'approved'
      and b.starts_at <= now() and (b.ends_at is null or b.ends_at > now()));
$$;

-- How many unrelated venues (distinct owners) barred this person in the last 12 months
create or replace function public.venue_bar_groups(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(distinct coalesce(v.owner_group, v.id))::int
  from venue_bars b join venues v on v.id = b.venue_id
  where b.user_id = p_user and b.status = 'approved' and b.starts_at > now() - interval '12 months';
$$;

create or replace function public.can_see_event(p_event uuid, p_viewer uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from events e
    where e.id = p_event
      and not is_barred(p_viewer, e.place_id)
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

create or replace function public.check_in(p_place uuid, p_hours int default 3, p_audience text default 'inner', p_notify boolean default false)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_until timestamptz := now() + make_interval(hours => least(greatest(coalesce(p_hours, 3), 1), 12));
  v_name text;
  v_place text;
  v_to uuid;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if coalesce(p_audience, '') not in ('inner','friends') then raise exception 'Pick who sees it.'; end if;
  select name into v_place from places where id = p_place;
  if v_place is null then raise exception 'Pick a place.'; end if;
  if is_barred(me, p_place) then raise exception 'You can''t check in here right now.'; end if;

  insert into checkins (user_id, place_id, audience, started_at, until)
  values (me, p_place, p_audience, now(), v_until)
  on conflict (user_id) do update set place_id = excluded.place_id, audience = excluded.audience,
                                      started_at = now(), until = excluded.until;

  if p_notify and not is_quiet(me) then
    select display_name into v_name from profiles where id = me;
    for v_to in
      select case when f.user_a = me then f.user_b else f.user_a end
      from friendships f
      where f.status = 'accepted' and me in (f.user_a, f.user_b)
        and (p_audience = 'friends' or (case when f.user_a = me then f.a_inner else f.b_inner end))
    loop
      perform notify(v_to, 'here_now', v_name || ' is at ' || v_place || ' right now.');
    end loop;
  end if;
  return v_until;
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
    'show_venue_badge', case when p.id = me and exists (select 1 from invite_redemptions r where r.user_id = p.id
                                 and r.code_kind in ('single','limited') and r.source_label is not null)
                             then coalesce(p.show_venue_badge, true) end
  );
end $$;

-- ---------------------------------------------------------------------
-- Becoming venue staff
-- ---------------------------------------------------------------------
create or replace function public.apply_for_venue(p_place uuid, p_role text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if p_role not in ('owner','manager') then raise exception 'Pick owner or manager.'; end if;
  if not exists (select 1 from places where id = p_place) then raise exception 'Pick the venue.'; end if;
  if exists (select 1 from venue_applications where user_id = me and place_id = p_place and status = 'pending') then
    raise exception 'You already applied. We''ll get back to you.';
  end if;
  insert into venue_applications (place_id, user_id, role, note) values (p_place, me, p_role, left(btrim(p_note), 500));
end $$;

create or replace function public.admin_venue_applications()
returns table (id bigint, place_id uuid, venue text, address text, user_id uuid, name text, role text, note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select a.id, pl.id, pl.name, pl.address, p.id, p.display_name, a.role, a.note, a.created_at
  from venue_applications a join places pl on pl.id = a.place_id join profiles p on p.id = a.user_id
  where a.status = 'pending' order by a.created_at;
end $$;

create or replace function public.admin_decide_venue_application(p_id bigint, p_ok boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  a venue_applications;
  v_venue uuid;
  v_name text;
begin
  perform require_admin();
  select * into a from venue_applications where id = p_id for update;
  if a.id is null or a.status <> 'pending' then return; end if;
  update venue_applications set status = case when p_ok then 'approved' else 'declined' end, decided_at = now() where id = p_id;
  select name into v_name from places where id = a.place_id;
  if not p_ok then
    perform notify(a.user_id, 'venue', 'We couldn''t confirm you for ' || v_name || '. Reply to us if that''s wrong.');
    return;
  end if;
  insert into venues (place_id, owner_group) values (a.place_id, case when a.role = 'owner' then a.user_id end)
  on conflict (place_id) do update set owner_group = coalesce(venues.owner_group, excluded.owner_group)
  returning id into v_venue;
  insert into venue_staff (venue_id, user_id, role) values (v_venue, a.user_id, a.role)
  on conflict (venue_id, user_id) do update set role = excluded.role;
  perform notify(a.user_id, 'venue', 'You''re confirmed as ' || a.role || ' of ' || v_name || '. Find it under You → My venue.');
end $$;

create or replace function public.my_venues()
returns table (venue_id uuid, place_id uuid, name text, address text, role text, capacity int,
               pending_tables int, pending_bars int)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return query
  select v.id, pl.id, pl.name, pl.address, s.role, v.capacity,
         (select count(*)::int from table_requests t where t.venue_id = v.id and t.status = 'pending' and t.starts_at > now()),
         (select count(*)::int from venue_bars b where b.venue_id = v.id and b.status = 'pending')
  from venue_staff s join venues v on v.id = s.venue_id join places pl on pl.id = v.place_id
  where s.user_id = me order by pl.name;
end $$;

create or replace function public.set_venue_capacity(p_venue uuid, p_capacity int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  update venues set capacity = p_capacity where id = p_venue;
end $$;

-- People who've been at the venue lately (checked in there, or going to plans there): who staff can act on
create or replace function public.get_venue_people(p_venue uuid)
returns table (user_id uuid, name text, photo text, last_seen timestamptz, how text, barred boolean)
language plpgsql stable security definer set search_path = public as $$
declare v venues;
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  select * into v from venues where id = p_venue;
  return query
  with seen as (
    select c.user_id as uid, c.started_at as at, 'Checked in' as how from checkins c where c.place_id = v.place_id
    union all
    select r.user_id, e.starts_at, 'Plan: ' || e.title from event_rsvps r join events e on e.id = r.event_id
     where e.place_id = v.place_id and e.starts_at > now() - interval '60 days'
  )
  select p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         max(s.at), (array_agg(s.how order by s.at desc))[1], is_barred(p.id, v.place_id)
  from seen s join profiles p on p.id = s.uid
  where not is_venue_staff(p_venue, p.id)
  group by p.id order by max(s.at) desc limit 100;
end $$;

-- ---------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------
create or replace function public.request_bar(p_venue uuid, p_user uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_len text;
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  if is_venue_staff(p_venue, p_user) then raise exception 'They''re staff here.'; end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Say what happened.'; end if;
  if exists (select 1 from venue_bars where venue_id = p_venue and user_id = p_user and status = 'pending') then
    raise exception 'There''s already a request for them.';
  end if;
  v_len := case when exists (select 1 from venue_bars where venue_id = p_venue and user_id = p_user
                                and status = 'approved' and length = '30_days')
                then 'indefinite' else '30_days' end;
  insert into venue_bars (venue_id, user_id, requested_by, reason, length)
  values (p_venue, p_user, me, left(btrim(p_reason), 1000), v_len);
  return v_len;
end $$;

create or replace function public.get_venue_bars(p_venue uuid)
returns table (bar_id uuid, user_id uuid, name text, reason text, length text, status text,
               ends_at timestamptz, appealed boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  return query
  select b.id, p.id, p.display_name, b.reason, b.length, b.status, b.ends_at, b.appealed_at is not null, b.created_at
  from venue_bars b join profiles p on p.id = b.user_id
  where b.venue_id = p_venue order by b.created_at desc limit 100;
end $$;

create or replace function public.admin_bar_requests()
returns table (bar_id uuid, venue text, user_id uuid, name text, requested_by text, reason text, length text,
               status text, appeal text, earlier_bars int, other_venues int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select b.id, pl.name, p.id, p.display_name, (select display_name from profiles where id = b.requested_by),
         b.reason, b.length, b.status, b.appeal,
         (select count(*)::int from venue_bars x where x.user_id = b.user_id and x.venue_id = b.venue_id and x.status = 'approved'),
         venue_bar_groups(b.user_id), b.created_at
  from venue_bars b join venues v on v.id = b.venue_id join places pl on pl.id = v.place_id join profiles p on p.id = b.user_id
  where b.status = 'pending' or (b.status = 'approved' and b.appealed_at is not null and b.decided_at < b.appealed_at)
  order by b.created_at;
end $$;

-- approve | decline | lift (lift = undo an approved bar, e.g. after an appeal) | uphold (keep it after an appeal)
create or replace function public.admin_decide_bar(p_bar uuid, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  b venue_bars;
  v_name text;
  v_place uuid;
begin
  perform require_admin();
  select * into b from venue_bars where id = p_bar for update;
  if b.id is null then return; end if;
  select pl.name, pl.id into v_name, v_place from venues v join places pl on pl.id = v.place_id where v.id = b.venue_id;

  if p_decision = 'approve' and b.status = 'pending' then
    update venue_bars set status = 'approved', starts_at = now(),
           ends_at = case when b.length = '30_days' then now() + interval '30 days' end,
           decided_at = now(), admin_note = left(p_note, 500)
     where id = b.id;
    -- drop their RSVPs to upcoming plans there
    delete from event_rsvps r using events e
     where r.event_id = e.id and r.user_id = b.user_id and e.place_id = v_place and e.starts_at > now() and e.creator_id <> b.user_id;
    delete from checkins where user_id = b.user_id and place_id = v_place;
    perform notify(b.user_id, 'venue_bar',
      case when b.length = '30_days'
           then v_name || ' has asked that you not come back for 30 days. Its plans are hidden from you until then. You can appeal under You.'
           else v_name || ' has asked that you not come back. Its plans are hidden from you. You can appeal under You.' end);
    if venue_bar_groups(b.user_id) >= 3 then
      perform notify(b.user_id, 'venue_bar', 'You''ve been barred by 3 unrelated venues this year, so your profile now shows it. It goes away as bars age off, or if an appeal succeeds.');
    end if;
  elsif p_decision = 'decline' and b.status = 'pending' then
    update venue_bars set status = 'declined', decided_at = now(), admin_note = left(p_note, 500) where id = b.id;
  elsif p_decision = 'lift' and b.status = 'approved' then
    update venue_bars set status = 'lifted', decided_at = clock_timestamp(), admin_note = left(p_note, 500) where id = b.id;
    perform notify(b.user_id, 'venue_bar', 'Your bar from ' || v_name || ' has been lifted.');
  elsif p_decision = 'uphold' and b.status = 'approved' then
    update venue_bars set decided_at = clock_timestamp(), admin_note = left(p_note, 500) where id = b.id;
    perform notify(b.user_id, 'venue_bar', 'We looked at your appeal about ' || v_name || '. The bar stays in place.');
  end if;
end $$;

-- The person's side: their bars and the appeal
create or replace function public.my_venue_bars()
returns table (bar_id uuid, venue text, length text, ends_at timestamptz, appealed boolean, decided_after_appeal boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return query
  select b.id, pl.name, b.length, b.ends_at, b.appealed_at is not null, b.appealed_at is not null and b.decided_at > b.appealed_at
  from venue_bars b join venues v on v.id = b.venue_id join places pl on pl.id = v.place_id
  where b.user_id = me and b.status = 'approved' and (b.ends_at is null or b.ends_at > now() - interval '12 months')
  order by b.starts_at desc;
end $$;

create or replace function public.appeal_bar(p_bar uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(btrim(coalesce(p_text, ''))) < 10 then raise exception 'Tell us a bit more (10+ characters).'; end if;
  update venue_bars set appeal = left(btrim(p_text), 1000), appealed_at = clock_timestamp()
   where id = p_bar and user_id = auth.uid() and status = 'approved' and appealed_at is null;
  if not found then raise exception 'You''ve already appealed this one.'; end if;
end $$;

-- ---------------------------------------------------------------------
-- Tables (reservations, phase 2)
-- ---------------------------------------------------------------------
create or replace function public.request_table(p_event uuid, p_party int, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  e events;
  v_venue uuid;
  v_name text;
begin
  select * into e from events where id = p_event;
  if e.id is null or e.creator_id <> me then raise exception 'Only whoever made the plan can ask for a table.'; end if;
  v_venue := venue_of(e.place_id);
  if v_venue is null then raise exception 'This place isn''t taking requests through Based.'; end if;
  if e.starts_at < now() then raise exception 'That plan already started.'; end if;
  insert into table_requests (venue_id, event_id, requested_by, party_size, starts_at, note)
  values (v_venue, e.id, me, least(greatest(coalesce(p_party, 2), 1), 200), e.starts_at, left(btrim(p_note), 300));
  select display_name into v_name from profiles where id = me;
  perform notify(s.user_id, 'table_request',
    v_name || ' asked for a table for ' || p_party || ' · ' || to_char(e.starts_at at time zone 'America/Edmonton', 'Dy FMHH12:MI AM'))
  from venue_staff s where s.venue_id = v_venue;
exception when unique_violation then
  raise exception 'There''s already a request for this plan.';
end $$;

create or replace function public.get_venue_tables(p_venue uuid)
returns table (request_id uuid, event_title text, requested_by text, party_size int, going int, starts_at timestamptz,
               note text, status text, approved_size int, staff_note text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_venue_staff(p_venue) then raise exception 'Not allowed.'; end if;
  return query
  select t.id, e.title, p.display_name, t.party_size,
         (select count(*)::int from event_rsvps r where r.event_id = t.event_id and r.status = 'going'),
         t.starts_at, t.note, t.status, t.approved_size, t.staff_note
  from table_requests t left join events e on e.id = t.event_id join profiles p on p.id = t.requested_by
  where t.venue_id = p_venue and t.starts_at > now() - interval '6 hours' and t.status <> 'cancelled'
  order by (t.status = 'pending') desc, t.starts_at;
end $$;

-- approve | partial (with a smaller size) | decline
create or replace function public.decide_table(p_request uuid, p_decision text, p_size int default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  t table_requests;
  v_name text;
  v_msg text;
begin
  select * into t from table_requests where id = p_request for update;
  if t.id is null or not is_venue_staff(t.venue_id) then raise exception 'Not allowed.'; end if;
  if p_decision not in ('approve','partial','decline') then raise exception 'Pick a decision.'; end if;
  update table_requests set
    status = case p_decision when 'approve' then 'approved' when 'partial' then 'partial' else 'declined' end,
    approved_size = case p_decision when 'approve' then t.party_size when 'partial' then least(greatest(coalesce(p_size, 1), 1), t.party_size) end,
    staff_note = left(btrim(p_note), 300), decided_by = auth.uid(), decided_at = now()
  where id = t.id;
  select pl.name into v_name from venues v join places pl on pl.id = v.place_id where v.id = t.venue_id;
  v_msg := case p_decision
             when 'approve' then v_name || ' is holding a table for ' || t.party_size || '.'
             when 'partial' then v_name || ' can hold a table for ' || least(greatest(coalesce(p_size, 1), 1), t.party_size) || ' (you asked for ' || t.party_size || ').'
             else v_name || ' can''t hold a table that night.' end
           || coalesce(' "' || nullif(btrim(p_note), '') || '"', '');
  perform notify(t.requested_by, 'table_reply', v_msg);
  -- let everyone going know too
  perform notify(r.user_id, 'table_reply', v_msg)
  from event_rsvps r where r.event_id = t.event_id and r.status = 'going' and r.user_id <> t.requested_by;
end $$;

-- What the event card shows: is this a partner venue, and what happened with the table
create or replace function public.event_table_status(p_event uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'partner', venue_of(e.place_id) is not null,
    'request', (select jsonb_build_object('status', t.status, 'party_size', t.party_size, 'approved_size', t.approved_size,
                                          'staff_note', t.staff_note)
                from table_requests t where t.event_id = e.id and t.status <> 'cancelled'
                order by t.created_at desc limit 1))
  from events e where e.id = p_event and can_see_event(e.id, auth.uid());
$$;

-- Queue counts now include venue items
create or replace function public.admin_queue_counts()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return jsonb_build_object(
    'reports', (select count(distinct reported_id) from reports where status = 'open'),
    'urgent', (select count(distinct reported_id) from reports where status = 'open' and priority),
    'photos', (select count(*) from manual_review where not checked),
    'bars', (select count(*) from admin_bar_requests()),
    'venues', (select count(*) from venue_applications where status = 'pending'));
end $$;

-- Push titles
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
      when 'venue'            then 'Your venue'
      when 'venue_bar'        then 'Venue access'
      when 'table_request'    then 'Table request'
      when 'table_reply'      then 'Your table'
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
    'public.apply_for_venue(uuid,text,text)', 'public.admin_venue_applications()', 'public.admin_decide_venue_application(bigint,boolean)',
    'public.my_venues()', 'public.set_venue_capacity(uuid,int)', 'public.get_venue_people(uuid)',
    'public.request_bar(uuid,uuid,text)', 'public.get_venue_bars(uuid)', 'public.admin_bar_requests()',
    'public.admin_decide_bar(uuid,text,text)', 'public.my_venue_bars()', 'public.appeal_bar(uuid,text)',
    'public.request_table(uuid,int,text)', 'public.get_venue_tables(uuid)', 'public.decide_table(uuid,text,int,text)',
    'public.event_table_status(uuid)', 'public.admin_queue_counts()', 'public.check_in(uuid,int,text,boolean)',
    'public.get_profile(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.venue_of(uuid)', 'public.is_venue_staff(uuid,uuid)', 'public.is_barred(uuid,uuid)',
    'public.venue_bar_groups(uuid)', 'public.can_see_event(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
