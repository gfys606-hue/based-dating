-- Invites: 7 a month instead of 3, FOR THE TESTING PHASE ONLY (Nov 5 2026).
--  * To go back to 3 a month at launch: re-run grant_invites from 20261105000059 and
--    get_my_invites from 20261105000064 (or change the two `else 7` back to `else 3`).
--  * First month stays 5 a week. Months 2 to 6: 7 a month (was 3). After 6 months: no refills.
--  * Members already in their monthly stretch are topped up to 7 now.
-- Replaces grant_invites (20261105000059) and get_my_invites (20261105000064). Safe to re-run.

create or replace function public.grant_invites(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  p profiles;
  v_phase text;
begin
  select * into p from profiles where id = p_user and status = 'active' for update;
  if p.id is null then return; end if;
  if p.invites_started_at is null then
    update profiles set invites_started_at = now() where id = p_user;
    p.invites_started_at := now();
  end if;
  v_phase := invite_phase(p.invites_started_at);
  if v_phase = 'done' then
    update profiles set invites_left = 0 where id = p_user;
    return;
  end if;
  update profiles
     set invites_left = case when invites_frozen_until > now() then 0
                             when v_phase = 'weekly' then 5 else 7 end,
         invite_grants = invite_grants + 1,
         last_invite_grant = now()
   where id = p_user;
end $$;

create or replace function public.get_my_invites()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  v_phase text;
  v_next timestamptz;
  v_owner boolean := is_admin(auth.uid());
begin
  select * into p from profiles where id = me;
  v_phase := invite_phase(p.invites_started_at);
  v_next := next_invite_grant(p.invites_started_at, p.last_invite_grant);
  return jsonb_build_object(
    'unlimited', v_owner,
    'left', case when v_owner then 999 when p.invites_frozen_until > now() then 0 else p.invites_left end,
    'frozen', not v_owner and coalesce(p.invites_frozen_until > now(), false),
    'phase', case when v_owner then 'unlimited' else v_phase end,
    'next_amount', case when v_owner or v_next is null then null
                        when v_next < p.invites_started_at + interval '28 days' then 5 else 7 end,
    'period', case when v_phase = 'weekly' then 'week' else 'month' end,
    'next_refill', case when v_owner then null else v_next end,
    'weeks_left', case when v_phase = 'weekly'
                       then greatest(0, ceil(extract(epoch from (p.invites_started_at + interval '28 days' - now())) / 604800.0))::int
                       else 0 end,
    'months_left', case when v_phase = 'done' then 0
                        else greatest(1, round(extract(epoch from (p.invites_started_at + interval '6 months' - now())) / 2592000.0))::int end,
    'codes', (select coalesce(jsonb_agg(jsonb_build_object(
                'code', c.code, 'used', c.uses > 0, 'active', c.active,
                'expires_at', c.expires_at, 'created_at', c.created_at,
                'joined', (select pr.display_name from invite_redemptions r join profiles pr on pr.id = r.user_id
                           where r.code = c.code limit 1))
              order by c.created_at desc), '[]')
              from invite_codes c where c.owner_id = me));
end $$;

-- Top up members who are in their monthly stretch right now
update public.profiles
   set invites_left = 7
 where status = 'active'
   and invite_phase(invites_started_at) = 'monthly'
   and coalesce(invites_frozen_until, '-infinity') < now()
   and invites_left < 7;
