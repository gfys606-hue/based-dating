-- Testing mode (Oct 23 2026): while the owner tests, every account gets full access.
--  * All modules (Herd, Events, plans) for every member, including people who join while it's on.
--  * Every Premium perk for everyone (50 picks, rewind, travel, premium voice prompts).
-- Turn it off before real users arrive (everyone but the owner goes back to new-member access):
--    select admin_set_testing_mode(false);
-- Turn it back on:
--    select admin_set_testing_mode(true);
-- Safe to re-run (re-running turns testing mode on).

create or replace function public.testing_mode()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value)::text::boolean from app_settings where key = 'testing_mode'), false);
$$;

create or replace function public.has_premium(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select testing_mode() or is_admin(p_user) or membership_tier(p_user) = 'premium';
$$;

create or replace function public.admin_set_testing_mode(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is not null then perform require_admin(); end if;
  insert into app_settings (key, value) values ('testing_mode', to_jsonb(coalesce(p_on, false)))
  on conflict (key) do update set value = excluded.value;
  insert into app_settings (key, value) values ('full_access_for_new', to_jsonb(coalesce(p_on, false)))
  on conflict (key) do update set value = excluded.value;
  if coalesce(p_on, false) then
    update profiles set is_tester = true where not is_tester and not is_test;
  else
    update profiles set is_tester = false where is_tester and not is_admin and not is_test;
    for r in select id from profiles where travel_until > now() and not has_premium(id) loop
      perform end_travel_for(r.id);
    end loop;
  end if;
end $$;

revoke all on function public.admin_set_testing_mode(boolean) from public, anon;
grant execute on function public.admin_set_testing_mode(boolean) to authenticated;
grant execute on function public.testing_mode() to authenticated;

select public.admin_set_testing_mode(true);
