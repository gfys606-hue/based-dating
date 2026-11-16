-- Expose each open city's center coordinates so onboarding can fall back to an
-- approximate location when a member's browser/device won't grant precise
-- location (e.g. a previously-denied permission that the page can't re-prompt
-- for). Lat/lng here is just the city's public center point, same for every
-- member in that city -- not sensitive.
--
-- get_cities() on production already carries a coming_soon/on_waitlist column
-- added outside this migration history, so this keeps that behavior and only
-- adds lat/lng. Postgres won't let CREATE OR REPLACE change a function's
-- return columns, hence the drop.

drop function if exists public.get_cities();

create function public.get_cities()
returns table (slug text, name text, region text, coming_soon boolean, lat double precision, lng double precision)
language sql stable security definer set search_path = public as $$
  select slug, name, region, (not active or on_waitlist), lat, lng
  from cities
  where active or on_waitlist
  order by active desc, sort, name;
$$;
