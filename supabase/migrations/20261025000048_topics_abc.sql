-- New post topic list: one A-Z list (members' topics mixed in), ignoring capitals. Safe to re-run.
create or replace function public.post_topics()
returns table (id int, name text, custom boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, t.custom from topics t where not t.hidden
  order by lower(t.name), t.name;
$$;
