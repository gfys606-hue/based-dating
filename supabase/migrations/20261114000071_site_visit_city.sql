-- Adds a city to each logged site visit (resolved from the visitor's IP by the new
-- track-visit edge function) and includes it in the owner's notification.

alter table public.site_visits add column if not exists city text;

-- Replaced by the 4-arg version below; drop the old 3-arg overload so it doesn't linger unused.
drop function if exists public.track_site_visit(text, text, text);

create or replace function public.track_site_visit(
  p_page text, p_visitor text, p_referrer text default null, p_city text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_recent boolean;
  v_owner uuid;
begin
  if coalesce(p_visitor, '') = '' then return; end if;

  select exists(
    select 1 from site_visits where visitor = p_visitor and created_at > now() - interval '30 minutes'
  ) into v_recent;

  insert into site_visits (visitor, page, referrer, city)
  values (p_visitor, left(coalesce(p_page, ''), 200), left(p_referrer, 300), left(p_city, 100));

  if v_recent then return; end if;  -- still logged above; just don't ping again so soon

  for v_owner in select id from profiles where is_admin and status <> 'banned' loop
    perform notify(v_owner, 'site_visit',
      'Someone''s on the site'
      || case when coalesce(p_city, '') <> '' then ' from ' || p_city else '' end
      || case when coalesce(p_page, '') <> '' then ' (' || p_page || ')' else '' end
      || '.');
  end loop;
end $$;

revoke all on function public.track_site_visit(text, text, text, text) from public, authenticated;
grant execute on function public.track_site_visit(text, text, text, text) to anon;
