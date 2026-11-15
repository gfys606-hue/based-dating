-- Expose each open city's center coordinates so onboarding can fall back to an
-- approximate location when a member's browser/device won't grant precise
-- location (e.g. a previously-denied permission that the page can't re-prompt
-- for). Lat/lng here is just the city's public center point, same for every
-- member in that city -- not sensitive.

create or replace function public.get_cities()
returns table (slug text, name text, region text, lat double precision, lng double precision)
language sql stable security definer set search_path = public as $$
  select slug, name, region, lat, lng from cities where active order by sort, name;
$$;
