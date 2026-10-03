-- Full access for new members (on at first): anyone who joins with an invite code gets the whole
-- platform (Circles, Events, plans) instead of just dating. You can switch it off in The door.

insert into public.app_settings (key, value) values ('full_access_for_new', 'true') on conflict (key) do nothing;

create or replace function public.full_access_for_new()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (value)::text::boolean from app_settings where key = 'full_access_for_new'), true);
$$;

create or replace function public.tg_profile_needs_invite()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if exists (select 1 from profiles where id = new.id) then return new; end if;  -- upsert of an existing profile
  -- a brand-new profile starts with no special powers
  -- while "full access for new members" is on, people who came in with a code get the whole platform
  new.is_tester := full_access_for_new() and has_redeemed() and new.id = auth.uid();
  new.is_admin := false;
  new.invites_left := 0;
  new.invite_grants := 0;
  new.last_invite_grant := null;
  new.invites_frozen_until := null;
  if invite_only() and (new.id is distinct from auth.uid() or not has_redeemed()) then
    raise exception 'An invite code is needed to join Based.';
  end if;
  return new;
end $$;

create or replace function public.admin_set_full_access(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  insert into app_settings (key, value) values ('full_access_for_new', to_jsonb(coalesce(p_on, true)))
  on conflict (key) do update set value = excluded.value;
end $$;

-- my_access: also report the full-access setting (for the admin screen)
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invite_only', invite_only(),
    'full_access_for_new', full_access_for_new(),
    'redeemed', exists (select 1 from invite_redemptions where user_id = auth.uid()),
    'has_profile', exists (select 1 from profiles where id = auth.uid()));
$$;

-- Anyone who already joined with a code gets it too
update public.profiles p set is_tester = true
where full_access_for_new() and not p.is_tester
  and exists (select 1 from invite_redemptions r where r.user_id = p.id);

revoke all on function public.full_access_for_new() from public, anon;
grant execute on function public.full_access_for_new() to authenticated;
revoke all on function public.admin_set_full_access(boolean) from public, anon;
grant execute on function public.admin_set_full_access(boolean) to authenticated;
