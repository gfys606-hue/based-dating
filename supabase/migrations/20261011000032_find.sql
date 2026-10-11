-- Search, kept inside Based: find people you know and places to go.
--  * People: by name. Friends first, then people in your herds, then friends of friends, then everyone
--    else in your city. Each comes with why you might know them ("Friend", "In Camping circle",
--    "3 mutual friends"). Blocked and hidden people never show.
--  * Places: Based places and partner venues by name or address, with how many of your friends go
--    there (saved as a watering hole) and who's there now (only people allowed to see you see you).
--    Venues that barred you don't show.
--  * Plans: upcoming plans you're allowed to see, by title or place.
--  * With an empty search box: people you may know and places your friends go.

create or replace function public.find(p_query text default '')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v profiles;
  q text := left(btrim(coalesce(p_query, '')), 100);
  pat text;
  browsing boolean;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  select * into v from profiles where id = me;
  browsing := char_length(q) < 2;
  pat := '%' || replace(replace(q, '%', ''), '_', '') || '%';

  return jsonb_build_object(
    'people', (select coalesce(jsonb_agg(x order by x.rank, x.mutual desc, x.km), '[]') from (
      select p.id, p.display_name as name,
             (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved') as photo,
             f.status as friendship, f.requested_by = me as requested_by_me,
             (select c.name from circle_members a join circle_members b on b.circle_id = a.circle_id and b.user_id = p.id
                join circles c on c.id = a.circle_id where a.user_id = me limit 1) as herd,
             m.n as mutual,
             case when f.status = 'accepted' then 0
                  when exists (select 1 from circle_members a join circle_members b on b.circle_id = a.circle_id
                               where a.user_id = me and b.user_id = p.id) then 1
                  when m.n > 0 then 2 else 3 end as rank,
             case when p.lat is null or v.lat is null then 99999 else round(haversine_km(v.lat, v.lng, p.lat, p.lng)::numeric, 1) end as km
      from profiles p
      left join friendships f on f.user_a = least(me, p.id) and f.user_b = greatest(me, p.id) and f.status in ('accepted', 'pending')
      cross join lateral (
        select count(*)::int as n from friendships f1 join friendships f2
          on (case when f1.user_a = me then f1.user_b else f1.user_a end) = (case when f2.user_a = p.id then f2.user_b else f2.user_a end)
        where (f1.user_a = me or f1.user_b = me) and f1.status = 'accepted'
          and (f2.user_a = p.id or f2.user_b = p.id) and f2.status = 'accepted') m
      where p.id <> me and p.status = 'active'
        and effective_tier(p.id) <> 'invisible'
        and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = p.id) or (b.blocker = p.id and b.blocked = me))
        and (case when browsing
                  -- people you may know: friends of friends and herd-mates you're not friends with yet
                  then coalesce(f.status, '') <> 'accepted'
                       and (m.n > 0 or exists (select 1 from circle_members a join circle_members b on b.circle_id = a.circle_id
                                                where a.user_id = me and b.user_id = p.id))
                  else p.display_name ilike pat
                       and (f.status = 'accepted' or m.n > 0 or p.city is not distinct from v.city
                            or exists (select 1 from circle_members a join circle_members b on b.circle_id = a.circle_id
                                       where a.user_id = me and b.user_id = p.id))
             end)
      order by 8, 7 desc, 9
      limit 20) x),

    'places', (select coalesce(jsonb_agg(x order by x.partner desc, x.friends_go desc, x.km), '[]') from (
      select pl.id, pl.name, pl.address, pl.lat, pl.lng,
             vn.id is not null as partner,
             coalesce(vn.featured_until > now(), false) as featured,
             (select count(*)::int from saved_places sp where sp.place_id = pl.id and are_friends(me, sp.user_id)) as friends_go,
             (select count(*)::int from checkins c where c.place_id = pl.id and c.until > now() and can_see_checkin(c.user_id, me)) as here_now,
             exists (select 1 from saved_places sp where sp.place_id = pl.id and sp.user_id = me) as saved,
             case when v.lat is null then 99999 else round(haversine_km(v.lat, v.lng, pl.lat, pl.lng)::numeric, 1) end as km
      from places pl left join venues vn on vn.place_id = pl.id
      where not is_barred(me, pl.id)
        and (v.lat is null or haversine_km(v.lat, v.lng, pl.lat, pl.lng) <= 60)
        and (case when browsing
                  then vn.id is not null or exists (select 1 from saved_places sp where sp.place_id = pl.id and are_friends(me, sp.user_id))
                  else pl.name ilike pat or pl.address ilike pat end)
      order by 6 desc, 8 desc, 11
      limit 20) x),

    'plans', (select coalesce(jsonb_agg(x order by x.starts_at), '[]') from (
      select e.id, e.title, coalesce(pl.name, e.place_name) as place, e.starts_at,
             a.display_name as host
      from events e join profiles a on a.id = e.creator_id
      left join places pl on pl.id = e.place_id
      where e.status = 'active' and e.starts_at > now() - interval '2 hours'
        and can_see_event(e.id, me)
        and (browsing and are_friends(me, e.creator_id)
             or not browsing and (e.title ilike pat or e.place_name ilike pat or pl.name ilike pat))
      order by e.starts_at
      limit 10) x)
  );
end $$;

revoke all on function public.find(text) from public, anon;
grant execute on function public.find(text) to authenticated;
