-- Owner-only full access (Oct 22 2026).
--  * The admin (the owner) always has everything: every module and every Premium perk, no expiry.
--  * Everyone else starts as a new member: Ouch (dating) only, free tier (25 picks a day, no rewind,
--    no travel mode, no premium voice prompts). Gifts stay 3 free a day while paid plans are closed.
--  * The owner gives more, per person, from Invites → Memberships:
--      Premium for 30 days / a year, and "All modules" (Herd, Events, plans).
--  * "Full access for new members" is switched off.
-- Note: is_admin can only be set from the dashboard / SQL editor; the app can never set it.
-- Safe to re-run.

-- ---------- the owner always has everything ----------
create or replace function public.is_tester(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_tester or is_admin from profiles where id = p_user), false);
$$;

create or replace function public.has_premium(p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select is_admin(p_user) or membership_tier(p_user) = 'premium';
$$;

create or replace function public.daily_pick_cap(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  select case when has_premium(p_user) then 50 else 25 end;
$$;

-- Losing Premium ends travel mode, whether or not paid plans are open
create or replace function public.after_tier_change(p_user uuid, p_was text)
returns void language plpgsql security definer set search_path = public as $$
declare
  now_tier text := membership_tier(p_user);
begin
  if now_tier = 'premium' and p_was <> 'premium' then
    perform grant_inner_bonus(p_user);
    perform notify(p_user, 'membership', 'Premium is on. Two extra invites are waiting for you.');
  end if;
  if not has_premium(p_user) then perform end_travel_for(p_user); end if;
end $$;

create or replace function public.inner_mark(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select has_premium(auth.uid()) and has_premium(p_user) and p_user <> auth.uid();
$$;

create or replace function public.my_membership()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tier', case when is_admin(auth.uid()) then 'premium' else membership_tier(auth.uid()) end,
    'premium', has_premium(auth.uid()),
    'owner', is_admin(auth.uid()),
    'open', memberships_open(),
    'source', case when is_admin(auth.uid()) then 'owner' else m.source end, 'status', m.status,
    'renews', case when m.cancel_at_period_end then null else m.current_period_end end,
    'ends',   case when m.cancel_at_period_end then m.current_period_end else null end,
    'has_billing', m.stripe_customer is not null,
    'daily_picks', daily_pick_cap(auth.uid()),
    'travel', (select case when p.travel_until > now()
                 then jsonb_build_object('name', p.travel_name, 'until', p.travel_until) end
               from profiles p where p.id = auth.uid()))
  from (select 1) one left join memberships m on m.user_id = auth.uid();
$$;

-- ---------- new members: dating only ----------
insert into public.app_settings (key, value) values ('full_access_for_new', 'false')
on conflict (key) do update set value = 'false';

-- Everyone who isn't the owner goes back to new-member access (test profiles untouched)
update public.profiles set is_tester = false where is_tester and not is_admin and not is_test;

-- Anyone travelling without Premium stops
do $$
declare r record;
begin
  for r in select id from profiles where travel_until > now() and not has_premium(id) loop
    perform end_travel_for(r.id);
  end loop;
end $$;

-- ---------- the owner gives more, one person at a time ----------
create or replace function public.admin_set_tester(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  if (select is_admin from profiles where id = p_user) then return; end if;
  update profiles set is_tester = coalesce(p_on, false) where id = p_user;
  if coalesce(p_on, false) then
    perform notify(p_user, 'membership', 'You''ve been given full access: Herd, Events and plans are open.');
  end if;
end $$;

drop function if exists public.admin_members(text);
create or replace function public.admin_members(p_query text default null)
returns table (user_id uuid, name text, email text, tier text, source text, until timestamptz,
               all_modules boolean, is_owner boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  perform require_admin();
  return query
  select p.id, p.display_name, u.email::text, membership_tier(p.id), m.source, m.current_period_end,
         p.is_tester or p.is_admin, p.is_admin
  from profiles p
  left join auth.users u on u.id = p.id
  left join memberships m on m.user_id = p.id
  where not p.is_test
    and ((p_query is null and (m.user_id is not null or p.is_tester or p.is_admin))
      or (p_query is not null and (p.display_name ilike '%' || p_query || '%' or u.email ilike '%' || p_query || '%')))
  order by p.is_admin desc, m.updated_at desc nulls last, p.display_name
  limit 50;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.admin_set_tester(uuid,boolean)', 'public.admin_members(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
