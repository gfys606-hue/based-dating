-- Confirm someone's actually near the city they're claiming to join.
-- set_city now takes an optional fresh GPS fix (p_lat/p_lng) from the device and checks it's
-- within 200 km of that city's coordinates (haversine_km, from 20260926000002_rules.sql).
-- If no fresh fix is passed, falls back to the profile's last known lat/lng (captured during
-- onboarding's location step / refreshMyLocation). If neither is available, or the city has no
-- coordinates on file (e.g. an admin-added city), the check is skipped rather than blocking.
-- A passed fix also updates the profile's lat/lng, same as refreshMyLocation does.

drop function if exists public.set_city(text);

create or replace function public.set_city(p_city text, p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_city public.cities;
  v_lat  double precision;
  v_lng  double precision;
  v_km   double precision;
begin
  select * into v_city from cities where slug = p_city and active;
  if v_city.slug is null then
    raise exception 'That city isn''t open yet.';
  end if;

  v_lat := coalesce(p_lat, (select lat from profiles where id = auth.uid()));
  v_lng := coalesce(p_lng, (select lng from profiles where id = auth.uid()));

  if v_city.lat is not null and v_city.lng is not null and v_lat is not null and v_lng is not null then
    v_km := haversine_km(v_lat, v_lng, v_city.lat, v_city.lng);
    if v_km > 200 then
      raise exception 'Your location looks to be about % km from %. You need to be within 200 km to join that city.',
        round(v_km)::int, v_city.name;
    end if;
  end if;

  update profiles
     set city = p_city,
         lat  = coalesce(p_lat, lat),
         lng  = coalesce(p_lng, lng)
   where id = auth.uid();

  return my_city();
end $$;

revoke all on function public.set_city(text, double precision, double precision) from public, anon;
grant execute on function public.set_city(text, double precision, double precision) to authenticated;
