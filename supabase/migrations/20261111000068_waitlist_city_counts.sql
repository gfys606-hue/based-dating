-- Per-city waitlist counter for the home page (based-social.com).
-- waitlist_cities() (used by site/index.html's city picker) now also returns how many
-- people are waiting for each city, open or coming-soon, so the home page can show it.
-- Safe to re-run.

drop function if exists public.waitlist_cities();

create or replace function public.waitlist_cities()
returns table (slug text, name text, region text, cap int, members int, open boolean, waiting int)
language sql stable security definer set search_path = public as $$
  select c.slug, c.name, c.region,
         case when c.active then c.member_cap end,
         case when c.active then city_members(c.slug) end,
         c.active,
         (select count(*)::int from waitlist w where w.city_slug = c.slug and w.status = 'waiting')
  from cities c where c.active or c.on_waitlist
  order by c.active desc, c.sort, c.name;
$$;

revoke all on function public.waitlist_cities() from public;
grant execute on function public.waitlist_cities() to anon, authenticated;
