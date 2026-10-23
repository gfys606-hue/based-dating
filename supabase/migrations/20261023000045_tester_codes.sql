-- Tester codes (Oct 23 2026). Owner only.
--  * The owner makes single-use tester codes from the app (You → Invite testers).
--  * Whoever signs up with one gets all modules (Herd, Events, plans) and, if chosen, Premium for N days.
--  * Normal invite and venue codes still give new-member access only.
-- Safe to re-run.

alter table public.invite_codes add column if not exists grants_tester boolean not null default false;
alter table public.invite_codes add column if not exists grants_premium_days int
  check (grants_premium_days is null or grants_premium_days between 1 and 3650);

-- Give the perks a tester code carries (once the person has a profile)
create or replace function public.apply_code_perks(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  c invite_codes;
begin
  select ic.* into c from invite_redemptions r join invite_codes ic on ic.code = r.code where r.user_id = p_user;
  if c.code is null or not exists (select 1 from profiles where id = p_user) then return; end if;
  if c.grants_tester then
    update profiles set is_tester = true where id = p_user and not is_tester;
  end if;
  if c.grants_premium_days is not null and not exists (select 1 from memberships where user_id = p_user) then
    insert into memberships (user_id, tier, source, status, current_period_end)
    values (p_user, 'premium', 'admin', 'active', now() + make_interval(days => c.grants_premium_days));
  end if;
end $$;
revoke all on function public.apply_code_perks(uuid) from public, anon, authenticated;

create or replace function public.tg_code_perks_redeemed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform apply_code_perks(new.user_id);
  return new;
end $$;
drop trigger if exists code_perks_redeemed on public.invite_redemptions;
create trigger code_perks_redeemed after insert on public.invite_redemptions
  for each row execute function public.tg_code_perks_redeemed();

create or replace function public.tg_code_perks_profile()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform apply_code_perks(new.id);
  return new;
end $$;
drop trigger if exists code_perks_profile on public.profiles;
create trigger code_perks_profile after insert on public.profiles
  for each row execute function public.tg_code_perks_profile();

-- Owner: make tester codes. Single use, good for p_days.
create or replace function public.admin_create_tester_codes(p_count int default 1, p_premium_days int default 90,
                                                            p_days int default 30, p_label text default 'Testers')
returns text[] language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  out_codes text[] := '{}';
  v text;
begin
  for i in 1..least(greatest(coalesce(p_count, 1), 1), 100) loop
    v := new_invite_code();
    insert into invite_codes (code, kind, source_label, max_uses, expires_at, created_by, grants_tester, grants_premium_days)
    values (v, 'single', left(coalesce(nullif(btrim(p_label), ''), 'Testers'), 60), 1,
            now() + make_interval(days => least(greatest(coalesce(p_days, 30), 1), 365)), me,
            true, case when coalesce(p_premium_days, 0) > 0 then least(p_premium_days, 3650) end);
    out_codes := out_codes || v;
  end loop;
  return out_codes;
end $$;

-- Owner: tester codes made so far
create or replace function public.admin_tester_codes()
returns table (code text, label text, premium_days int, used boolean, expires_at timestamptz, active boolean,
               used_by text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select c.code, c.source_label, c.grants_premium_days, c.uses >= c.max_uses, c.expires_at, c.active,
         (select p.display_name from invite_redemptions r join profiles p on p.id = r.user_id where r.code = c.code limit 1),
         c.created_at
  from invite_codes c where c.grants_tester
  order by c.created_at desc limit 200;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.admin_create_tester_codes(int,int,int,text)', 'public.admin_tester_codes()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- Turning testing mode off keeps the access tester codes gave
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
    update profiles p set is_tester = false
     where p.is_tester and not p.is_admin and not p.is_test
       and not exists (select 1 from invite_redemptions ir join invite_codes c on c.code = ir.code
                        where ir.user_id = p.id and c.grants_tester);
    for r in select id from profiles where travel_until > now() and not has_premium(id) loop
      perform end_travel_for(r.id);
    end loop;
  end if;
end $$;
