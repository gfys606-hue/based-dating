-- Invites: 7 a month instead of 3, FOR THE TESTING PHASE ONLY (Nov 5 2026).
--  * Written against the schedule that is live (20261003000019: one grant every 30 days, 6 grants).
--    20261105000059 (weekly first month) and 20261105000064 (owner unlimited) were NOT applied to
--    the live database when this ran.
--  * Active members with a grant in the last 30 days were topped up to 7.
--  * To go back to 3 a month at launch: change `else 7` back to `else 3` and re-run grant_invites.

begin;

create or replace function public.grant_invites(p_user uuid)
returns void language plpgsql security definer set search_path to 'public' as $f$
begin
  update profiles
     set invites_left = case when invites_frozen_until > now() then 0 else 7 end,
         invite_grants = invite_grants + 1,
         last_invite_grant = now()
   where id = p_user and status = 'active' and invite_grants < 6;
end $f$;

update public.profiles
   set invites_left = 7
 where status = 'active' and not is_admin
   and invite_grants between 1 and 6
   and last_invite_grant >= now() - interval '30 days'
   and coalesce(invites_frozen_until, '-infinity') < now()
   and invites_left < 7;

commit;
