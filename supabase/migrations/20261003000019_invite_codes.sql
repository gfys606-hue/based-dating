-- Invite codes: the door is not for everyone.
--  * New sign-ups need a code (or join the waitlist). Everyone already in keeps their access.
--  * Three kinds: single-use (bartender passes), limited-use (drink menus), personal (members' own invites).
--  * Venue codes carry a label ("Heavily Redacted") for stats and the optional "Joined through" badge.
--  * Members get 3 personal invites a month for their first 6 months (unused ones don't roll over).
--  * Quiet accountability: if someone you invited gets banned, your invites are frozen for 90 days.

create table if not exists public.app_settings (
  key   text primary key,
  value jsonb not null
);
insert into public.app_settings (key, value) values ('invite_only', 'true') on conflict (key) do nothing;
alter table public.app_settings enable row level security;  -- functions only

alter table public.profiles add column if not exists is_admin boolean not null default false;
alter table public.profiles add column if not exists invites_left int not null default 0;
alter table public.profiles add column if not exists invite_grants int not null default 0;
alter table public.profiles add column if not exists last_invite_grant timestamptz;
alter table public.profiles add column if not exists invites_frozen_until timestamptz;
alter table public.profiles add column if not exists show_venue_badge boolean not null default true;

create table if not exists public.invite_codes (
  code         text primary key,
  kind         text not null check (kind in ('single','limited','personal')),
  source_label text check (char_length(source_label) <= 60),
  max_uses     int not null default 1 check (max_uses between 1 and 10000),
  uses         int not null default 0,
  expires_at   timestamptz,
  active       boolean not null default true,
  owner_id     uuid references public.profiles(id) on delete cascade,  -- personal codes
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists invite_codes_owner on public.invite_codes (owner_id);
create index if not exists invite_codes_label on public.invite_codes (source_label);

create table if not exists public.invite_redemptions (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  code         text not null references public.invite_codes(code) on delete cascade,
  code_kind    text not null,
  source_label text,
  inviter_id   uuid references public.profiles(id) on delete set null,
  redeemed_at  timestamptz not null default now()
);
create index if not exists invite_redemptions_inviter on public.invite_redemptions (inviter_id);

create table if not exists public.invite_attempts (
  user_id uuid not null,
  at      timestamptz not null default now()
);

create table if not exists public.waitlist (
  id          bigserial primary key,
  email       text not null unique check (char_length(email) between 5 and 200),
  name        text check (char_length(name) <= 60),
  note        text check (char_length(note) <= 300),
  status      text not null default 'waiting' check (status in ('waiting','invited')),
  invite_code text references public.invite_codes(code) on delete set null,
  created_at  timestamptz not null default now()
);

alter table public.invite_codes       enable row level security;
alter table public.invite_redemptions enable row level security;
alter table public.invite_attempts    enable row level security;
alter table public.waitlist           enable row level security;

-- Your account is the first admin
update public.profiles set is_admin = true
where id in (select id from auth.users where lower(email) = 'gfys.606@gmail.com');

create or replace function public.is_admin(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = p_user), false);
$$;

create or replace function public.invite_only()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value)::text::boolean from app_settings where key = 'invite_only'), true);
$$;

-- 8 easy-to-read characters, e.g. 7KXQ-M4TB (no 0/O, 1/I/L)
create or replace function public.new_invite_code()
returns text language plpgsql volatile set search_path = public as $$
declare
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  bytes bytea;
  c text;
begin
  loop
    bytes := decode(md5(gen_random_uuid()::text || clock_timestamp()::text), 'hex');
    c := '';
    for i in 0..7 loop
      c := c || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
      if i = 3 then c := c || '-'; end if;
    end loop;
    exit when not exists (select 1 from invite_codes where code = c);
  end loop;
  return c;
end $$;

-- ---------------------------------------------------------------------
-- The door
-- ---------------------------------------------------------------------
-- What the app needs to decide whether to show the code screen
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invite_only', invite_only(),
    'redeemed', exists (select 1 from invite_redemptions where user_id = auth.uid()),
    'has_profile', exists (select 1 from profiles where id = auth.uid()));
$$;

create or replace function public.redeem_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c invite_codes;
  v text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if exists (select 1 from invite_redemptions where user_id = me) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if (select count(*) from invite_attempts where user_id = me and at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many tries. Wait an hour and try again.';
  end if;
  if char_length(v) = 8 then v := left(v, 4) || '-' || right(v, 4); end if;

  select * into c from invite_codes where code = v for update;
  if c.code is null or not c.active or (c.expires_at is not null and c.expires_at < now()) or c.uses >= c.max_uses then
    insert into invite_attempts (user_id) values (me);
    raise exception 'That code isn''t valid. Check it and try again.';
  end if;

  update invite_codes set uses = uses + 1 where code = c.code;
  insert into invite_redemptions (user_id, code, code_kind, source_label, inviter_id)
  values (me, c.code, c.kind, c.source_label, c.owner_id);
  delete from invite_attempts where user_id = me;
  return jsonb_build_object('ok', true, 'label', c.source_label,
    'inviter', (select display_name from profiles where id = c.owner_id));
end $$;

-- Members can't hand themselves admin, tester or extra invites
create or replace function public.tg_profile_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    new.status               := old.status;
    new.pause_reason         := old.pause_reason;
    new.selfie_verified      := old.selfie_verified;
    new.ad_free              := old.ad_free;
    new.created_at           := old.created_at;
    new.is_tester            := old.is_tester;
    new.is_admin             := old.is_admin;
    new.invites_left         := old.invites_left;
    new.invite_grants        := old.invite_grants;
    new.last_invite_grant    := old.last_invite_grant;
    new.invites_frozen_until := old.invites_frozen_until;
  end if;
  return new;
end $$;

create or replace function public.has_redeemed()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from invite_redemptions where user_id = auth.uid());
$$;

-- New profiles need a redeemed code while the door is invite-only (existing members are untouched).
-- Runs as the caller (not security definer) so it can tell a member's own insert from the system's.
create or replace function public.tg_profile_needs_invite()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if exists (select 1 from profiles where id = new.id) then return new; end if;  -- upsert of an existing profile
  -- a brand-new profile starts with no special powers
  new.is_tester := false;
  new.is_admin := false;
  new.invites_left := 0;
  new.invite_grants := 0;
  new.last_invite_grant := null;
  new.invites_frozen_until := null;
  if invite_only() and (new.id is distinct from auth.uid() or not has_redeemed()) then
    raise exception 'An invite code is needed to join Based.';
  end if;
  return new;
end $$;

drop trigger if exists profile_needs_invite on public.profiles;
create trigger profile_needs_invite before insert on public.profiles
for each row execute function public.tg_profile_needs_invite();

-- Anyone (signed in or not) can ask to be let in
create or replace function public.join_waitlist(p_email text, p_name text default null, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare e text := lower(btrim(coalesce(p_email, '')));
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a real email.'; end if;
  insert into waitlist (email, name, note) values (e, left(btrim(p_name), 60), left(btrim(p_note), 300))
  on conflict (email) do nothing;
end $$;

-- ---------------------------------------------------------------------
-- Personal invites
-- ---------------------------------------------------------------------
-- 3 a month for the first 6 months of membership; unused ones don't roll over; frozen = none
create or replace function public.grant_invites(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles
     set invites_left = case when invites_frozen_until > now() then 0 else 3 end,
         invite_grants = invite_grants + 1,
         last_invite_grant = now()
   where id = p_user and status = 'active' and invite_grants < 6;
end $$;

create or replace function public.refill_invites()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; u uuid;
begin
  for u in select id from profiles
           where status = 'active' and invite_grants between 1 and 5
             and last_invite_grant < now() - interval '30 days' loop
    perform grant_invites(u);
    n := n + 1;
  end loop;
  -- after the 6th month, any leftover invites from the last grant expire with it
  update profiles set invites_left = 0
   where invite_grants >= 6 and invites_left > 0 and last_invite_grant < now() - interval '30 days';
  return n;
end $$;
select cron.schedule('refill-invites', '23 9 * * *', $$select public.refill_invites()$$);

-- First grant when someone becomes an active member; freeze the inviter if they get banned
create or replace function public.tg_profile_invite_events()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_inviter uuid;
begin
  if new.status = 'active' and old.status is distinct from 'active' and new.invite_grants = 0 then
    perform grant_invites(new.id);
  end if;
  if new.status = 'banned' and old.status is distinct from 'banned' then
    select inviter_id into v_inviter from invite_redemptions where user_id = new.id;
    if v_inviter is not null then
      update profiles set invites_frozen_until = now() + interval '90 days', invites_left = 0 where id = v_inviter;
      update invite_codes set active = false where owner_id = v_inviter and uses = 0;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists profile_invite_events on public.profiles;
create trigger profile_invite_events after update of status on public.profiles
for each row execute function public.tg_profile_invite_events();

-- Existing members start with their first month of invites
update public.profiles set invites_left = 3, invite_grants = 1, last_invite_grant = now()
where status = 'active' and invite_grants = 0;

create or replace function public.create_personal_invite()
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  v text;
begin
  select * into p from profiles where id = me for update;
  if p.status <> 'active' then raise exception 'Only active members can invite.'; end if;
  if p.invites_frozen_until > now() then raise exception 'Your invites are paused for now.'; end if;
  if p.invites_left <= 0 then raise exception 'You''re out of invites for this month.'; end if;
  v := new_invite_code();
  insert into invite_codes (code, kind, max_uses, owner_id, created_by, expires_at)
  values (v, 'personal', 1, me, me, now() + interval '30 days');
  update profiles set invites_left = invites_left - 1 where id = me;
  return v;
end $$;

create or replace function public.get_my_invites()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
begin
  select * into p from profiles where id = me;
  return jsonb_build_object(
    'left', case when p.invites_frozen_until > now() then 0 else p.invites_left end,
    'frozen', coalesce(p.invites_frozen_until > now(), false),
    'months_left', greatest(0, 6 - p.invite_grants),
    'next_refill', case when p.invite_grants < 6 and p.last_invite_grant is not null
                        then p.last_invite_grant + interval '30 days' end,
    'codes', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', c.code, 'used', c.uses > 0, 'active', c.active,
                'expires_at', c.expires_at, 'created_at', c.created_at,
                'joined', (select pr.display_name from invite_redemptions r join profiles pr on pr.id = r.user_id
                           where r.code = c.code limit 1))
              order by c.created_at desc), '[]')
              from invite_codes c where c.owner_id = me));
end $$;

-- ---------------------------------------------------------------------
-- Admin (you)
-- ---------------------------------------------------------------------
create or replace function public.require_admin()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not is_admin(me) then raise exception 'Not allowed.'; end if;
  return me;
end $$;

-- kind: single (each code works once) or limited (one code, p_max_uses people). p_days: expiry (null = never)
create or replace function public.admin_create_codes(p_kind text, p_label text, p_count int default 1,
                                                     p_max_uses int default 1, p_days int default null)
returns text[] language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  out_codes text[] := '{}';
  v text;
begin
  if p_kind not in ('single','limited') then raise exception 'Pick single or limited.'; end if;
  if coalesce(btrim(p_label), '') = '' then raise exception 'Give the batch a label, like the venue name.'; end if;
  for i in 1..(case when p_kind = 'limited' then 1 else least(greatest(coalesce(p_count, 1), 1), 200) end) loop
    v := new_invite_code();
    insert into invite_codes (code, kind, source_label, max_uses, expires_at, created_by)
    values (v, p_kind, left(btrim(p_label), 60),
            case when p_kind = 'limited' then least(greatest(coalesce(p_max_uses, 50), 2), 10000) else 1 end,
            case when p_days is null then null else now() + make_interval(days => p_days) end, me);
    out_codes := out_codes || v;
  end loop;
  return out_codes;
end $$;

-- Sign-ups by label: codes made, codes used, people who finished joining
create or replace function public.admin_invite_stats()
returns table (label text, kind text, codes int, capacity int, used int, joined int, active_members int, last_used timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  with c as (
    select x.*, coalesce(x.source_label, case when x.kind = 'personal' then 'Member invites' else 'No label' end) as lbl
    from invite_codes x
  ),
  r as (
    select c.lbl, count(*)::int as joined,
           count(*) filter (where p.status = 'active')::int as active_members,
           max(rd.redeemed_at) as last_used
    from invite_redemptions rd join c on c.code = rd.code left join profiles p on p.id = rd.user_id
    group by c.lbl
  )
  select c.lbl,
         case when count(distinct c.kind) = 1 then min(c.kind) else 'mixed' end,
         count(*)::int, sum(c.max_uses)::int, sum(c.uses)::int,
         coalesce(max(r.joined), 0), coalesce(max(r.active_members), 0), max(r.last_used)
  from c left join r on r.lbl = c.lbl
  group by c.lbl
  order by 6 desc, 1;
end $$;

create or replace function public.admin_list_codes(p_label text)
returns table (code text, kind text, max_uses int, uses int, active boolean, expires_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.code, c.kind, c.max_uses, c.uses, c.active, c.expires_at, c.created_at
  from invite_codes c
  where c.kind <> 'personal' and c.source_label = p_label
  order by c.created_at desc, c.code;
end $$;

create or replace function public.admin_set_code_active(p_code text, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update invite_codes set active = p_active where code = p_code;
end $$;

create or replace function public.admin_set_invite_only(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  insert into app_settings (key, value) values ('invite_only', to_jsonb(coalesce(p_on, true)))
  on conflict (key) do update set value = excluded.value;
end $$;

create or replace function public.admin_waitlist()
returns table (id bigint, email text, name text, note text, status text, invite_code text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query select w.id, w.email, w.name, w.note, w.status, w.invite_code, w.created_at
               from waitlist w order by (w.status = 'waiting') desc, w.created_at;
end $$;

-- Let someone in from the waitlist: makes a single-use code labelled "Waitlist" (you send it to them)
create or replace function public.admin_admit_waitlist(p_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  v text;
begin
  select invite_code into v from waitlist where id = p_id;
  if v is not null then return v; end if;
  v := new_invite_code();
  insert into invite_codes (code, kind, source_label, max_uses, created_by, expires_at)
  values (v, 'single', 'Waitlist', 1, me, now() + interval '30 days');
  update waitlist set status = 'invited', invite_code = v where id = p_id;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- get_profile: add the venue badge
-- ---------------------------------------------------------------------
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
    'show_venue_badge', case when p.id = me and exists (select 1 from invite_redemptions r where r.user_id = p.id
                                 and r.code_kind in ('single','limited') and r.source_label is not null)
                             then coalesce(p.show_venue_badge, true) end
  );
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.my_access()', 'public.redeem_invite(text)', 'public.create_personal_invite()', 'public.get_my_invites()',
    'public.is_admin(uuid)', 'public.admin_create_codes(text,text,int,int,int)', 'public.admin_invite_stats()',
    'public.admin_list_codes(text)', 'public.admin_set_code_active(text,boolean)', 'public.admin_set_invite_only(boolean)',
    'public.admin_waitlist()', 'public.admin_admit_waitlist(bigint)', 'public.get_profile(uuid)',
    'public.invite_only()', 'public.has_redeemed()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- the waitlist form works before signing up
  revoke all on function public.join_waitlist(text,text,text) from public;
  grant execute on function public.join_waitlist(text,text,text) to anon, authenticated;
  foreach f in array array[
    'public.new_invite_code()', 'public.grant_invites(uuid)', 'public.refill_invites()',
    'public.require_admin()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- Shows how many admin accounts exist (should be 1: yours)
select count(*) as admins from public.profiles where is_admin;
