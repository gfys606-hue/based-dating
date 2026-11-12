-- Approval-gated openings (Nov 12 2026): no one without an invite code is ever let in
-- automatically. "Spot drops" (a scheduled, automatic cap raise) are retired.
--  * When a city is full and people are waiting, the system notices and asks the owner
--    whether to open some spots -- it never opens any on its own.
--  * The owner approves (choosing how many) or declines from the admin dashboard; only
--    an explicit approval calls admit_from_line.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Retire the old automatic mechanism
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from cron.job where jobname = 'spot-drops') then
    perform cron.unschedule('spot-drops');
  end if;
end $$;

drop function if exists public.admin_schedule_drop(text, int, timestamptz);
drop function if exists public.admin_cancel_drop(bigint);
drop function if exists public.release_due_drops();
drop table if exists public.spot_drops;

-- ---------------------------------------------------------------------
-- Pending opening requests: raised automatically, decided only by the owner
-- ---------------------------------------------------------------------
create table if not exists public.city_opening_requests (
  id           bigserial primary key,
  city         text not null references public.cities(slug) on delete cascade,
  suggested_n  int not null,
  waiting_n    int not null,
  status       text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  decided_n    int,
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_at   timestamptz,
  created_at   timestamptz not null default now()
);
alter table public.city_opening_requests enable row level security;  -- functions only
create index if not exists city_opening_requests_open on public.city_opening_requests (city) where status = 'pending';

-- Full city + people waiting + no open request already pending for it -> ask the owner.
-- Driven by a daily cron tick; also checked whenever the door or admin screen is looked at,
-- so the owner never waits a full day for the first ping.
create or replace function public.check_city_openings()
returns int language plpgsql security definer set search_path = public as $$
declare
  c cities;
  v_waiting int;
  v_id bigint;
  v_owner uuid;
  n int := 0;
begin
  for c in select * from cities where active and member_cap is not null loop
    if coalesce(city_spots_left(c.slug), 1) > 0 then continue; end if;
    if exists (select 1 from city_opening_requests where city = c.slug and status = 'pending') then continue; end if;
    select count(*)::int into v_waiting from waitlist where city_slug = c.slug and status = 'waiting';
    if v_waiting <= 0 then continue; end if;
    insert into city_opening_requests (city, suggested_n, waiting_n)
    values (c.slug, least(v_waiting, 50), v_waiting)
    returning id into v_id;
    for v_owner in select id from profiles where is_admin and status <> 'banned' loop
      perform notify(v_owner, 'opening',
        city_name(c.slug) || ' is full with ' || v_waiting
        || (case when v_waiting = 1 then ' person' else ' people' end)
        || ' waiting. Approve an opening in The door whenever you''re ready.');
    end loop;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'city-openings-check') then
      perform cron.unschedule('city-openings-check');
    end if;
    perform cron.schedule('city-openings-check', '0 15 * * *', 'select public.check_city_openings()');  -- ~9am Calgary
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Owner review: see what's pending, approve (and choose how many) or decline
-- ---------------------------------------------------------------------
create or replace function public.admin_pending_openings()
returns table (id bigint, city text, name text, suggested_n int, waiting_n int, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  perform check_city_openings();  -- catch anything due right now, not just at the daily tick
  return query
  select r.id, r.city, c.name, r.suggested_n, r.waiting_n, r.created_at
  from city_opening_requests r join cities c on c.slug = r.city
  where r.status = 'pending'
  order by r.created_at;
end $$;

-- Only this lets anyone in without a code: an explicit, named owner decision.
create or replace function public.admin_approve_opening(p_id bigint, p_n int default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  r city_opening_requests;
  v_n int;
  v_admitted int;
begin
  select * into r from city_opening_requests where id = p_id and status = 'pending' for update;
  if r.id is null then raise exception 'That request isn''t pending anymore.'; end if;
  v_n := greatest(1, coalesce(p_n, r.suggested_n));
  update cities set member_cap = coalesce(member_cap, city_members(slug)) + v_n where slug = r.city;
  v_admitted := admit_from_line(r.city, coalesce(city_spots_left(r.city), v_n));
  update city_opening_requests set status = 'approved', decided_n = v_admitted, decided_by = me, decided_at = now()
  where id = p_id;
  return v_admitted;
end $$;

create or replace function public.admin_decline_opening(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_admin();
begin
  update city_opening_requests set status = 'declined', decided_by = me, decided_at = now()
  where id = p_id and status = 'pending';
end $$;

-- ---------------------------------------------------------------------
-- Drop "next_drop" from what the door and admin screens return
-- ---------------------------------------------------------------------
create or replace function public.city_door(p_city text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_city text;
  c cities;
  w waitlist;
begin
  v_city := coalesce((select slug from cities where slug = p_city and active),
                     case when me is null then default_city() else joining_city(me) end);
  select * into c from cities where slug = v_city;
  if c.slug is null then return null; end if;
  select * into w from waitlist where user_id = me;
  return jsonb_build_object(
    'slug', c.slug, 'name', c.name, 'region', c.region,
    'cap', c.member_cap,
    'members', city_members(c.slug),
    'spots_left', city_spots_left(c.slug),
    'waiting', (select count(*)::int from waitlist where city_slug = c.slug and status = 'waiting'),
    'my_status', w.status,
    'my_position', line_position(me),
    'my_vouched', coalesce(w.vouches, 0) > 0);
end $$;

drop function if exists public.admin_cities();
create or replace function public.admin_cities()
returns table (slug text, name text, region text, active boolean, members int,
               cap int, spots_left int, waiting int, drinking_age int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.slug, c.name, c.region, c.active, city_members(c.slug), c.member_cap, city_spots_left(c.slug),
         (select count(*)::int from waitlist w where w.city_slug = c.slug and w.status = 'waiting'),
         c.drinking_age
  from cities c order by c.active desc, c.sort, c.name;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array['public.check_city_openings()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.admin_pending_openings()', 'public.admin_approve_opening(bigint,int)', 'public.admin_decline_opening(bigint)',
    'public.admin_cities()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.city_door(text)'] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
