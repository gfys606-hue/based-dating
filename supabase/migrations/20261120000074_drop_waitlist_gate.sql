-- Drop the waitlist gate, keep city caps (Nov 20 2026):
--  * No invite code is required to join anymore -- people sign up directly in the app.
--  * City member caps are untouched and still block a full city at signup (tg_profile_needs_invite).
--  * Everyone who was already sitting on the waitlist gets full access: each affected city's cap is
--    raised by exactly its waiting count, and those waitlist rows are marked admitted.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- 1) Turn off the invite-code requirement. City caps alone still gate signup.
-- ---------------------------------------------------------------------
insert into public.app_settings (key, value) values ('invite_only', 'false')
on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------
-- 2) Raise each city's cap to cover everyone currently waiting there, then
--    mark those rows admitted so nobody who already signed up is blocked.
-- ---------------------------------------------------------------------
do $$
declare
  c record;
  v_waiting int;
begin
  for c in select slug, member_cap from public.cities loop
    select count(*)::int into v_waiting
    from public.waitlist
    where city_slug = c.slug and status = 'waiting';

    if v_waiting > 0 then
      update public.cities
         set member_cap = coalesce(member_cap, public.city_members(c.slug)) + v_waiting
       where slug = c.slug;
    end if;
  end loop;
end $$;

update public.waitlist
   set status = 'admitted',
       admitted_at = coalesce(admitted_at, now())
 where status = 'waiting';
