-- City caps, spot drops and a real waitlist line (priority 1, Oct 19 2026).
--  * Every city has a member cap (Calgary starts at 2,500), shown on the website.
--  * When a city is full, codes still work but put you at the FRONT of the line instead of straight in
--    (a member vouching for you moves you up; nobody can pay to skip).
--  * The cap rises through timed "spot drops" ("500 new Calgary spots drop Friday at 8").
--    At drop time the people at the front of the line are let in automatically.
--  * Bars and venue promos only show to members at or over the local drinking age (Alberta = 18).
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Cities: cap + drinking age
-- ---------------------------------------------------------------------
alter table public.cities add column if not exists member_cap int check (member_cap is null or member_cap >= 0);
alter table public.cities add column if not exists drinking_age int not null default 18 check (drinking_age between 16 and 25);
update public.cities set member_cap = 2500 where slug = 'calgary' and member_cap is null;

-- ---------------------------------------------------------------------
-- Waitlist: bring the live table up to date (it was missing name/note/status/code) + the line
-- ---------------------------------------------------------------------
alter table public.waitlist add column if not exists name text;
alter table public.waitlist add column if not exists note text;
alter table public.waitlist add column if not exists status text not null default 'waiting';
alter table public.waitlist add column if not exists invite_code text references public.invite_codes(code) on delete set null;
alter table public.waitlist add column if not exists city text;
alter table public.waitlist add column if not exists user_id uuid references auth.users(id) on delete cascade;
alter table public.waitlist add column if not exists city_slug text references public.cities(slug);
alter table public.waitlist add column if not exists vouches int not null default 0;
alter table public.waitlist add column if not exists last_vouched_at timestamptz;
alter table public.waitlist add column if not exists admitted_at timestamptz;
alter table public.waitlist drop constraint if exists waitlist_status_check;
alter table public.waitlist add constraint waitlist_status_check check (status in ('waiting','invited','admitted'));
create unique index if not exists waitlist_user on public.waitlist (user_id) where user_id is not null;
-- one entry per email, any capitalization (the live table already has this as waitlist_email_key)
do $$
begin
  if not exists (select 1 from pg_indexes where tablename = 'waitlist' and indexdef ilike '%(lower(email))%' and indexdef ilike '%unique%') then
    create unique index waitlist_email_lower on public.waitlist (lower(email));
  end if;
end $$;
create index if not exists waitlist_line on public.waitlist (city_slug, status, created_at);
update public.waitlist w set city_slug = c.slug
  from public.cities c
 where w.city_slug is null and w.city is not null and lower(trim(w.city)) in (c.slug, lower(c.name));

alter table public.invite_redemptions add column if not exists city text references public.cities(slug);

create table if not exists public.spot_drops (
  id          bigserial primary key,
  city        text not null references public.cities(slug) on delete cascade,
  spots       int not null check (spots between 1 and 100000),
  drop_at     timestamptz not null,
  released_at timestamptz,
  admitted    int,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.spot_drops enable row level security;  -- functions only

-- ---------------------------------------------------------------------
-- Counting seats
-- ---------------------------------------------------------------------
create or replace function public.default_city()
returns text language sql stable security definer set search_path = public as $$
  select slug from cities where active order by sort, name limit 1;
$$;

create or replace function public.city_members(p_city text)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from profiles where city = p_city and status in ('onboarding','active','paused');
$$;

-- seats promised but not yet filled: codes used without a profile yet, and waitlist codes still out
create or replace function public.city_reserved(p_city text)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*)::int from invite_redemptions r
           where r.city = p_city and r.redeemed_at > now() - interval '30 days'
             and not exists (select 1 from profiles p where p.id = r.user_id))
       + (select count(*)::int from waitlist w join invite_codes ic on ic.code = w.invite_code
           where w.city_slug = p_city and w.status = 'invited'
             and ic.active and ic.uses < ic.max_uses and (ic.expires_at is null or ic.expires_at > now()));
$$;

-- null = no cap
create or replace function public.city_spots_left(p_city text)
returns int language sql stable security definer set search_path = public as $$
  select case when c.member_cap is null then null
              else greatest(0, c.member_cap - city_members(c.slug) - city_reserved(c.slug)) end
  from cities c where c.slug = p_city;
$$;

create or replace function public.redemption_city(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select city from invite_redemptions where user_id = p_user;
$$;

create or replace function public.city_name(p_city text)
returns text language sql stable security definer set search_path = public as $$
  select name from cities where slug = p_city;
$$;

-- the city a person is trying to get into (their waitlist city, else the first open city)
create or replace function public.joining_city(p_user uuid default auth.uid())
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select w.city_slug from waitlist w join cities c on c.slug = w.city_slug and c.active where w.user_id = p_user),
    default_city());
$$;

create or replace function public.line_position(p_user uuid default auth.uid())
returns int language sql stable security definer set search_path = public as $$
  with me as (select * from waitlist where user_id = p_user and status = 'waiting')
  select case when not exists (select 1 from me) then null else
    (select count(*)::int + 1 from waitlist w, me
      where w.status = 'waiting' and w.city_slug is not distinct from me.city_slug and w.id <> me.id
        and ((w.vouches > 0)::int > (me.vouches > 0)::int
          or ((w.vouches > 0) = (me.vouches > 0) and (w.vouches > me.vouches
               or (w.vouches = me.vouches and w.created_at < me.created_at))))) end;
$$;

-- ---------------------------------------------------------------------
-- Joining the line
-- ---------------------------------------------------------------------
drop function if exists public.join_waitlist(text, text, text);
create or replace function public.join_waitlist(p_email text, p_name text default null, p_note text default null,
                                                p_city text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e text := lower(btrim(coalesce(p_email, '')));
  v_city text := coalesce((select slug from cities where slug = p_city and active), default_city());
  me uuid := auth.uid();
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a real email.'; end if;
  if me is not null and exists (select 1 from waitlist where user_id = me and email <> e) then
    update waitlist set email = e where user_id = me;
  end if;
  insert into waitlist (email, name, note, city, city_slug, user_id)
  values (e, left(nullif(btrim(p_name), ''), 60), left(nullif(btrim(p_note), ''), 300),
          (select name from cities where slug = v_city), v_city, me)
  on conflict ((lower(email))) do update
    set user_id   = coalesce(waitlist.user_id, excluded.user_id),
        name      = coalesce(excluded.name, waitlist.name),
        note      = coalesce(excluded.note, waitlist.note),
        city_slug = coalesce(waitlist.city_slug, excluded.city_slug);
  return jsonb_build_object('ok', true, 'position', line_position(me));
end $$;

-- ---------------------------------------------------------------------
-- Codes: straight in when there's room, front of the line when the city is full
-- ---------------------------------------------------------------------
create or replace function public.redeem_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c invite_codes;
  v text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_city text;
  v_left int;
  v_email text;
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
  delete from invite_attempts where user_id = me;
  v_city := joining_city(me);
  v_left := city_spots_left(v_city);

  if v_left is not null and v_left <= 0 then
    -- full: the code vouches for you and moves you to the front of the line
    select email into v_email from auth.users where id = me;
    insert into waitlist (email, user_id, city, city_slug, vouches, last_vouched_at, note)
    values (lower(v_email), me, (select name from cities where slug = v_city), v_city, 1, now(),
            'Vouched: ' || coalesce(c.source_label, (select display_name from profiles where id = c.owner_id), 'code'))
    on conflict ((lower(email))) do update
      set user_id = coalesce(waitlist.user_id, excluded.user_id),
          city_slug = coalesce(waitlist.city_slug, excluded.city_slug),
          vouches = waitlist.vouches + 1, last_vouched_at = now();
    return jsonb_build_object('ok', false, 'waitlisted', true,
      'city', (select name from cities where slug = v_city),
      'position', line_position(me),
      'inviter', (select display_name from profiles where id = c.owner_id),
      'label', c.source_label);
  end if;

  insert into invite_redemptions (user_id, code, code_kind, source_label, inviter_id, city)
  values (me, c.code, c.kind, c.source_label, c.owner_id, v_city);
  update waitlist set status = 'admitted', admitted_at = now() where user_id = me;
  return jsonb_build_object('ok', true, 'label', c.source_label,
    'inviter', (select display_name from profiles where id = c.owner_id));
end $$;

-- New profiles land in the city they got a seat in; with the door open (no codes), the cap still holds
create or replace function public.tg_profile_needs_invite()
returns trigger language plpgsql set search_path = public as $$
declare v_city text;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if exists (select 1 from profiles where id = new.id) then return new; end if;  -- upsert of an existing profile
  new.is_tester := full_access_for_new() and has_redeemed() and new.id = auth.uid();
  new.is_admin := false;
  new.invites_left := 0;
  new.invite_grants := 0;
  new.last_invite_grant := null;
  new.invites_frozen_until := null;
  if invite_only() and (new.id is distinct from auth.uid() or not has_redeemed()) then
    raise exception 'An invite code is needed to join Based.';
  end if;
  v_city := redemption_city(new.id);
  if v_city is not null then
    new.city := v_city;
  elsif coalesce(city_spots_left(new.city), 1) <= 0 then
    raise exception '% is full right now. Join the waitlist for the next spot drop.', city_name(new.city);
  end if;
  return new;
end $$;

-- Moving to a full city isn't allowed (travel mode is separate and unaffected)
create or replace function public.tg_city_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.city is distinct from old.city then
    if not exists (select 1 from public.cities where slug = new.city and active) then
      raise exception 'That city isn''t open yet.';
    end if;
    if coalesce(public.city_spots_left(new.city), 1) <= 0 then
      raise exception 'That city is full right now.';
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- Spot drops
-- ---------------------------------------------------------------------
-- Let the front of a city's line in. People who already have an account get in automatically;
-- email-only sign-ups get a code (listed in The door so you can send it).
create or replace function public.admit_from_line(p_city text, p_n int)
returns int language plpgsql security definer set search_path = public as $$
declare
  w waitlist;
  v text;
  n int := 0;
begin
  if coalesce(p_n, 0) <= 0 then return 0; end if;
  for w in
    select * from waitlist
     where status = 'waiting' and city_slug = p_city
     order by (vouches > 0) desc, vouches desc, created_at
     limit p_n
     for update skip locked
  loop
    v := new_invite_code();
    if w.user_id is not null and not exists (select 1 from invite_redemptions where user_id = w.user_id) then
      insert into invite_codes (code, kind, source_label, max_uses, uses, expires_at)
      values (v, 'single', 'Spot drop', 1, 1, now() + interval '30 days');
      insert into invite_redemptions (user_id, code, code_kind, source_label, city)
      values (w.user_id, v, 'single', 'Spot drop', p_city);
      update waitlist set status = 'admitted', admitted_at = now(), invite_code = v where id = w.id;
    else
      insert into invite_codes (code, kind, source_label, max_uses, expires_at)
      values (v, 'single', 'Spot drop', 1, now() + interval '14 days');
      update waitlist set status = 'invited', invite_code = v where id = w.id;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.release_due_drops()
returns int language plpgsql security definer set search_path = public as $$
declare
  d spot_drops;
  n int := 0;
  v_in int;
begin
  for d in select * from spot_drops where released_at is null and drop_at <= now() order by drop_at for update skip locked loop
    update cities set member_cap = coalesce(member_cap, city_members(slug)) + d.spots where slug = d.city;
    v_in := admit_from_line(d.city, coalesce(city_spots_left(d.city), d.spots));
    update spot_drops set released_at = now(), admitted = v_in where id = d.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('spot-drops', '* * * * *', 'select public.release_due_drops()');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- What the website / door screen shows (works before signing in)
-- ---------------------------------------------------------------------
create or replace function public.city_door(p_city text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_city text;
  c cities;
  d spot_drops;
  w waitlist;
begin
  perform release_due_drops();   -- a drop that's due happens the moment anyone looks
  v_city := coalesce((select slug from cities where slug = p_city and active),
                     case when me is null then default_city() else joining_city(me) end);
  select * into c from cities where slug = v_city;
  if c.slug is null then return null; end if;
  select * into d from spot_drops where city = v_city and released_at is null order by drop_at limit 1;
  select * into w from waitlist where user_id = me;
  return jsonb_build_object(
    'slug', c.slug, 'name', c.name, 'region', c.region,
    'cap', c.member_cap,
    'members', city_members(c.slug),
    'spots_left', city_spots_left(c.slug),
    'waiting', (select count(*)::int from waitlist where city_slug = c.slug and status = 'waiting'),
    'next_drop', case when d.id is null then null else jsonb_build_object('spots', d.spots, 'at', d.drop_at) end,
    'my_status', w.status,
    'my_position', line_position(me),
    'my_vouched', coalesce(w.vouches, 0) > 0);
end $$;

-- ---------------------------------------------------------------------
-- Drinking age: bars and venue promos only for members at or over the local age
-- ---------------------------------------------------------------------
create or replace function public.bars_ok(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select extract(year from age(p.birthdate))::int >= c.drinking_age
                     from profiles p join cities c on c.slug = p.city where p.id = p_user), false);
$$;

create or replace function public.my_city()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('slug', c.slug, 'name', c.name, 'region', c.region,
                            'cap', c.member_cap, 'members', city_members(c.slug), 'bars_ok', bars_ok())
  from profiles p join cities c on c.slug = p.city where p.id = auth.uid();
$$;

create or replace function public.get_partner_venues(p_km int default 15)
returns table (venue_id uuid, place_id uuid, name text, address text, lat double precision, lng double precision,
               distance_km double precision, friends_here int, featured boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
begin
  if not bars_ok(me) then return; end if;
  select * into v from profiles where id = me;
  return query
  select vn.id, pl.id, pl.name, pl.address, pl.lat, pl.lng,
         case when v.lat is null then null else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1)::double precision end,
         (select count(*)::int from checkins c where c.place_id = pl.id and c.until > now() and can_see_checkin(c.user_id, me)),
         coalesce(vn.featured_until > now(), false)
  from venues vn join places pl on pl.id = vn.place_id
  where not is_barred(me, pl.id)
    and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= coalesce(p_km, 15))
  order by coalesce(vn.featured_until > now(), false) desc,
           case when v.lat is null then 0 else haversine_km(v.lat, v.lng, pl.lat, pl.lng) end
  limit 20;
end $$;

-- ---------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------
drop function if exists public.admin_cities();
create or replace function public.admin_cities()
returns table (slug text, name text, region text, active boolean, members int,
               cap int, spots_left int, waiting int, drinking_age int, next_drop jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.slug, c.name, c.region, c.active, city_members(c.slug), c.member_cap, city_spots_left(c.slug),
         (select count(*)::int from waitlist w where w.city_slug = c.slug and w.status = 'waiting'),
         c.drinking_age,
         (select jsonb_build_object('id', d.id, 'spots', d.spots, 'at', d.drop_at)
            from spot_drops d where d.city = c.slug and d.released_at is null order by d.drop_at limit 1)
  from cities c order by c.active desc, c.sort, c.name;
end $$;

create or replace function public.admin_set_city_rules(p_city text, p_cap int, p_drinking_age int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update cities set member_cap = p_cap, drinking_age = coalesce(p_drinking_age, drinking_age) where slug = p_city;
end $$;

create or replace function public.admin_schedule_drop(p_city text, p_spots int, p_at timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := require_admin(); v bigint;
begin
  if p_at is null then raise exception 'Pick a time.'; end if;
  insert into spot_drops (city, spots, drop_at, created_by) values (p_city, p_spots, p_at, me) returning id into v;
  return v;
end $$;

create or replace function public.admin_cancel_drop(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  delete from spot_drops where id = p_id and released_at is null;
end $$;

drop function if exists public.admin_waitlist();
create or replace function public.admin_waitlist()
returns table (id bigint, email text, name text, note text, status text, invite_code text, created_at timestamptz,
               city text, vouches int, has_account boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query select w.id, w.email, w.name, w.note, w.status, w.invite_code, w.created_at,
                      coalesce(c.name, w.city), w.vouches, w.user_id is not null
               from waitlist w left join cities c on c.slug = w.city_slug
               order by (w.status = 'waiting') desc, (w.vouches > 0) desc, w.vouches desc, w.created_at;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.default_city()', 'public.city_members(text)', 'public.city_reserved(text)',
    'public.joining_city(uuid)', 'public.line_position(uuid)', 'public.admit_from_line(text,int)',
    'public.release_due_drops()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.redeem_invite(text)', 'public.bars_ok(uuid)', 'public.city_spots_left(text)',
    'public.redemption_city(uuid)', 'public.city_name(text)', 'public.my_city()', 'public.get_partner_venues(int)',
    'public.admin_cities()', 'public.admin_set_city_rules(text,int,int)', 'public.admin_schedule_drop(text,int,timestamptz)',
    'public.admin_cancel_drop(bigint)', 'public.admin_waitlist()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- before signing in: the website shows the city's door, and anyone can join the line
  foreach f in array array['public.city_door(text)', 'public.join_waitlist(text,text,text,text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
