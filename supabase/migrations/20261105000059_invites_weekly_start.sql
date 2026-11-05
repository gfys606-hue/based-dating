-- Invites, new schedule (Nov 3 2026):
--  * First month: 5 invites a week (4 weekly grants). After that: 3 a month until 6 months in. Then no refills.
--  * Unused invites still don't carry over (each grant resets the count).
--  * Paused invites (someone you invited got banned) stay paused.
--  * When a city hits its cap and demand grows, the owner can open extra invites to that city's members
--    first (admin_city_invites); the waitlist comes after that.
-- Replaces grant_invites / refill_invites / get_my_invites from 20261003000019. Safe to re-run.

alter table public.profiles add column if not exists invites_started_at timestamptz;

-- Existing members: their invite clock started when they joined
update public.profiles set invites_started_at = coalesce(
    (select r.redeemed_at from invite_redemptions r where r.user_id = profiles.id), created_at)
where invites_started_at is null and status = 'active';

-- Members can't move their own invite clock
create or replace function public.tg_profile_invite_clock_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    if tg_op = 'INSERT' then
      new.invites_started_at := null;
    else
      new.invites_started_at := old.invites_started_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profile_invite_clock_guard on public.profiles;
create trigger profile_invite_clock_guard before insert or update on public.profiles
for each row execute function public.tg_profile_invite_clock_guard();

-- Where someone is in their invite schedule right now
--  phase: 'weekly' (first 28 days), 'monthly' (until 6 months), 'done'
create or replace function public.invite_phase(p_started timestamptz)
returns text language sql stable as $$
  select case when p_started is null then 'weekly'
              when now() < p_started + interval '28 days' then 'weekly'
              when now() < p_started + interval '6 months' then 'monthly'
              else 'done' end;
$$;

create or replace function public.grant_invites(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  p profiles;
  v_phase text;
begin
  select * into p from profiles where id = p_user and status = 'active' for update;
  if p.id is null then return; end if;
  if p.invites_started_at is null then
    update profiles set invites_started_at = now() where id = p_user;
    p.invites_started_at := now();
  end if;
  v_phase := invite_phase(p.invites_started_at);
  if v_phase = 'done' then
    update profiles set invites_left = 0 where id = p_user;
    return;
  end if;
  update profiles
     set invites_left = case when invites_frozen_until > now() then 0
                             when v_phase = 'weekly' then 5 else 3 end,
         invite_grants = invite_grants + 1,
         last_invite_grant = now()
   where id = p_user;
end $$;

-- When the next grant is due (null = no more)
create or replace function public.next_invite_grant(p_started timestamptz, p_last timestamptz)
returns timestamptz language sql stable as $$
  select case
    when p_started is null or p_last is null then null
    when now() >= p_started + interval '6 months' then null
    -- last grant was a weekly one: the next comes a week later (the one at day 28 is the first monthly)
    when p_last < p_started + interval '28 days' then p_last + interval '7 days'
    else p_last + interval '30 days' end;
$$;

create or replace function public.refill_invites()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; u uuid;
begin
  for u in select id from profiles
           where status = 'active' and invite_grants >= 1
             and invites_started_at > now() - interval '6 months'
             and next_invite_grant(invites_started_at, last_invite_grant) <= now() loop
    perform grant_invites(u);
    n := n + 1;
  end loop;
  -- after six months, leftovers from the last grant expire with it
  update profiles set invites_left = 0
   where invites_left > 0 and invites_started_at <= now() - interval '6 months'
     and coalesce(last_invite_grant, '-infinity') < now() - interval '30 days';
  return n;
end $$;

-- Daily is enough for monthly grants but weekly ones should land on the day; run every hour
do $$
begin
  if exists (select 1 from cron.job where jobname = 'refill-invites') then perform cron.unschedule('refill-invites'); end if;
  perform cron.schedule('refill-invites', '23 * * * *', 'select public.refill_invites()');
end $$;

create or replace function public.get_my_invites()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  v_phase text;
  v_next timestamptz;
begin
  select * into p from profiles where id = me;
  v_phase := invite_phase(p.invites_started_at);
  v_next := next_invite_grant(p.invites_started_at, p.last_invite_grant);
  return jsonb_build_object(
    'left', case when p.invites_frozen_until > now() then 0 else p.invites_left end,
    'frozen', coalesce(p.invites_frozen_until > now(), false),
    'phase', v_phase,
    -- what the next grant resets you to, and how the app should word the period
    'next_amount', case when v_next is null then null
                        when v_next < p.invites_started_at + interval '28 days' then 5 else 3 end,
    'period', case when v_phase = 'weekly' then 'week' else 'month' end,
    'next_refill', v_next,
    'weeks_left', case when v_phase = 'weekly'
                       then greatest(0, ceil(extract(epoch from (p.invites_started_at + interval '28 days' - now())) / 604800.0))::int
                       else 0 end,
    'months_left', case when v_phase = 'done' then 0
                        else greatest(1, round(extract(epoch from (p.invites_started_at + interval '6 months' - now())) / 2592000.0))::int end,
    'codes', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', c.code, 'used', c.uses > 0, 'active', c.active,
                'expires_at', c.expires_at, 'created_at', c.created_at,
                'joined', (select pr.display_name from invite_redemptions r join profiles pr on pr.id = r.user_id
                           where r.code = c.code limit 1))
              order by c.created_at desc), '[]')
              from invite_codes c where c.owner_id = me));
end $$;

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
  if p.invites_left <= 0 then
    raise exception '%', case when invite_phase(p.invites_started_at) = 'weekly'
                              then 'You''re out of invites for this week.'
                              when invite_phase(p.invites_started_at) = 'monthly'
                              then 'You''re out of invites for this month.'
                              else 'You''re out of invites.' end;
  end if;
  v := new_invite_code();
  insert into invite_codes (code, kind, max_uses, owner_id, created_by, expires_at)
  values (v, 'personal', 1, me, me, now() + interval '30 days');
  update profiles set invites_left = invites_left - 1 where id = me;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- Owner: open extra invites to a city's members (members first, then the waitlist)
-- Adds p_count invites to every active member in the city, even past their 6 months.
-- ---------------------------------------------------------------------
create or replace function public.admin_city_invites(p_city text, p_count int)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform require_admin();
  if coalesce(p_count, 0) not between 1 and 10 then raise exception 'Pick 1 to 10 invites.'; end if;
  update profiles
     set invites_left = invites_left + p_count
   where city = p_city and status = 'active'
     and coalesce(invites_frozen_until, '-infinity') < now();
  get diagnostics n = row_count;
  perform notify(id, 'invites',
    p_count || case when p_count = 1 then ' extra invite' else ' extra invites' end
    || ' just opened up for members. Use them on people you''d vouch for.')
  from profiles where city = p_city and status = 'active' and coalesce(invites_frozen_until, '-infinity') < now();
  return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.get_my_invites()', 'public.create_personal_invite()', 'public.admin_city_invites(text,int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.grant_invites(uuid)', 'public.refill_invites()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
