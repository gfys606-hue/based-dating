-- More cities on the waitlist picker (Nov 5 2026): Edmonton, Vancouver and Toronto.
--  * They show on the website and in the app's waitlist as "coming soon": people can sign up for them,
--    but nobody can join as a member there until you open the city (The door → cities).
--  * Signups for a coming-soon city are saved under that city's name, so opening it later links them
--    automatically (admin_set_city_active), same as any "somewhere else" signup.
-- Safe to re-run.

alter table public.cities add column if not exists on_waitlist boolean not null default false;

-- The website signup writes these; make sure they exist (they were first added outside the migrations)
alter table public.waitlist add column if not exists is_adult boolean;
alter table public.waitlist add column if not exists source text;

insert into public.cities (slug, name, region, lat, lng, active, on_waitlist, sort, drinking_age) values
  ('edmonton',  'Edmonton',  'Alberta',          53.5461, -113.4938, false, true, 10, 18),
  ('vancouver', 'Vancouver', 'British Columbia', 49.2827, -123.1207, false, true, 20, 19),
  ('toronto',   'Toronto',   'Ontario',          43.6532,  -79.3832, false, true, 30, 19)
on conflict (slug) do update set on_waitlist = true;

-- Picker: open cities first, then coming-soon ones. Same columns as before, plus "open".
drop function if exists public.waitlist_cities();
create or replace function public.waitlist_cities()
returns table (slug text, name text, region text, cap int, members int, open boolean)
language sql stable security definer set search_path = public as $$
  select c.slug, c.name, c.region,
         case when c.active then c.member_cap end,
         case when c.active then city_members(c.slug) end,
         c.active
  from cities c where c.active or c.on_waitlist
  order by c.active desc, c.sort, c.name;
$$;

-- Owner: put a city on (or take it off) the waitlist picker without opening it
create or replace function public.admin_set_city_waitlist(p_city text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update cities set on_waitlist = coalesce(p_on, false) where slug = p_city;
  if not found then raise exception 'No such city.'; end if;
end $$;

do $$
begin
  execute 'revoke all on function public.waitlist_cities() from public';
  execute 'grant execute on function public.waitlist_cities() to anon, authenticated';
  execute 'revoke all on function public.admin_set_city_waitlist(text,boolean) from public, anon';
  execute 'grant execute on function public.admin_set_city_waitlist(text,boolean) to authenticated';
end $$;
