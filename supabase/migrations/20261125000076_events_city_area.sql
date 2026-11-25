-- Events: show public events across the member's whole city area, not just within their feed/circle distance.
--  * A public event is visible if it's within 75 km of the member's city centre (the city and its surrounding
--    towns, e.g. Okotoks/Turner Valley for Calgary, Burnaby for Vancouver).
--  * If the city has no centre point, fall back to 75 km from the member's own location.
--  * p_km is kept so the app doesn't need an update, but it no longer limits public events.
--  * Friends / inner circle / custom / circle plans were never distance-limited and still aren't.
--  * distance_km on each event is still measured from the member, for display.

create or replace function public.get_events(p_km int default 50, p_circle uuid default null)
returns table (event_id uuid, title text, details text, topic text, place_name text,
               starts_at timestamptz, distance_km int, going int, capacity int,
               my_rsvp text, mine boolean, circle_id uuid, circle_name text, creator_name text,
               audience text, invited_count int, place_id uuid, place_address text,
               place_lat double precision, place_lng double precision)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_area_km constant double precision := 75;
  v_clat double precision;
  v_clng double precision;
begin
  select * into v from profiles where id = me;
  select c.lat, c.lng into v_clat, v_clng from cities c where c.slug = v.city;
  v_clat := coalesce(v_clat, v.lat);
  v_clng := coalesce(v_clng, v.lng);

  return query
  select e.id, e.title, e.details, t.name, e.place_name, e.starts_at,
         case when e.lat is null or v.lat is null then null
              else greatest(1, round(haversine_km(v.lat, v.lng, e.lat, e.lng)))::int end,
         (select count(*)::int from event_rsvps r where r.event_id = e.id and r.status = 'going'),
         e.capacity,
         (select r.status from event_rsvps r where r.event_id = e.id and r.user_id = me),
         e.creator_id = me, e.circle_id, c.name, cr.display_name,
         e.audience,
         case when e.creator_id = me and e.audience = 'custom'
              then (select count(*)::int from event_invitees i where i.event_id = e.id) end,
         pl.id, pl.address, pl.lat, pl.lng
  from events e
  left join topics t on t.id = e.topic_id
  left join circles c on c.id = e.circle_id
  left join places pl on pl.id = e.place_id
  join profiles cr on cr.id = e.creator_id
  where e.status = 'active'
    and e.starts_at > now() - interval '2 hours'
    and (p_circle is null or e.circle_id = p_circle)
    and can_see_event(e.id, me)
    and (e.audience <> 'public' or e.creator_id = me or e.lat is null or v_clat is null
         or haversine_km(v_clat, v_clng, e.lat, e.lng) <= v_area_km)
  order by
    (e.audience in ('inner','custom','friends')) desc,
    (exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = e.topic_id)) desc,
    e.starts_at
  limit 100;
end $$;
