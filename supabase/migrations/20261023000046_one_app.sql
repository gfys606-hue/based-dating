-- One app (Oct 23 2026): dating and every social part (Herd, Search, Events, Market, plans) are one app.
--  * Every member gets all of it. There's no "dating only" version any more.
--  * Premium is still separate (perks, not parts of the app).
--  * Testing mode now only switches Premium perks on for everyone.
--  * Tester codes now give Premium (if chosen); the "all modules" part no longer matters.
-- Safe to re-run.

-- Every member (not suspended or banned) has every part of the app
create or replace function public.is_tester(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = p_user and status in ('onboarding','active','paused'));
$$;

create or replace function public.require_tester()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or not is_tester(me) then raise exception 'Sign in to use this.'; end if;
  return me;
end $$;

-- Testing mode: Premium perks for everyone (on/off)
create or replace function public.admin_set_testing_mode(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is not null then perform require_admin(); end if;
  insert into app_settings (key, value) values ('testing_mode', to_jsonb(coalesce(p_on, false)))
  on conflict (key) do update set value = excluded.value;
  if not coalesce(p_on, false) then
    for r in select id from profiles where travel_until > now() and not has_premium(id) loop
      perform end_travel_for(r.id);
    end loop;
  end if;
end $$;

-- The app shows the whole platform to everyone; keep the column true so older app versions agree
update public.profiles set is_tester = true where not is_tester;
alter table public.profiles alter column is_tester set default true;

create or replace function public.tg_profile_needs_invite()
returns trigger language plpgsql set search_path = public as $$
declare v_city text;
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if exists (select 1 from profiles where id = new.id) then return new; end if;  -- upsert of an existing profile
  new.is_tester := true;
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
