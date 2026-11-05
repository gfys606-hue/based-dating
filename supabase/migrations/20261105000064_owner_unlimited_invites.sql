-- The owner's account has unlimited personal invites (Nov 5 2026).
-- Everyone else keeps the schedule from 20261105000059. Safe to re-run.

create or replace function public.create_personal_invite()
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  v text;
  v_owner boolean := is_admin(auth.uid());
begin
  select * into p from profiles where id = me for update;
  if p.status <> 'active' and not v_owner then raise exception 'Only active members can invite.'; end if;
  if not v_owner then
    if p.invites_frozen_until > now() then raise exception 'Your invites are paused for now.'; end if;
    if p.invites_left <= 0 then
      raise exception '%', case when invite_phase(p.invites_started_at) = 'weekly'
                                then 'You''re out of invites for this week.'
                                when invite_phase(p.invites_started_at) = 'monthly'
                                then 'You''re out of invites for this month.'
                                else 'You''re out of invites.' end;
    end if;
  end if;
  v := new_invite_code();
  insert into invite_codes (code, kind, max_uses, owner_id, created_by, expires_at)
  values (v, 'personal', 1, me, me, now() + interval '30 days');
  if not v_owner then update profiles set invites_left = invites_left - 1 where id = me; end if;
  return v;
end $$;

-- Same shape as before, plus 'unlimited' (true for the owner)
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
                        when v_next < p.invites_started_at + interval '28 days' then 5 else 3 end,
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
