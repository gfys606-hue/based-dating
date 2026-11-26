-- Terms of Use acceptance (based-social.com/terms.html).
--  * Joining now means agreeing to the house rules AND the Terms of Use + Privacy Policy, on the same
--    "I'm in" screen. We record which version of the terms each member accepted, and when.
--  * Bump current_terms_version() when the terms change significantly: everyone is asked to accept
--    again the next time they open the app.
--  * Existing members are asked once, the next time they open the app.

alter table public.profiles add column if not exists house_rules_at timestamptz;
alter table public.profiles add column if not exists terms_version int;
alter table public.profiles add column if not exists terms_at timestamptz;

create or replace function public.current_terms_version()
returns int language sql immutable as $$ select 1 $$;

create or replace function public.my_house_rules()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'accepted', (select house_rules_at is not null and coalesce(terms_version, 0) >= current_terms_version()
                   from profiles where id = auth.uid()),
    'terms_version', current_terms_version(),
    'rules', house_rules());
$$;

-- Accepting covers the house rules and the current terms (older app versions call this too).
create or replace function public.accept_house_rules()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in again.'; end if;
  update profiles
     set house_rules_at = coalesce(house_rules_at, now()),
         terms_at = case when coalesce(terms_version, 0) >= current_terms_version() then terms_at else now() end,
         terms_version = greatest(coalesce(terms_version, 0), current_terms_version())
   where id = auth.uid();
end $$;

-- Members can't set acceptance themselves (only through accept_house_rules)
create or replace function public.tg_profile_rules_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    if tg_op = 'INSERT' then
      new.house_rules_at := null; new.terms_version := null; new.terms_at := null;
    else
      new.house_rules_at := old.house_rules_at; new.terms_version := old.terms_version; new.terms_at := old.terms_at;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profile_rules_guard on public.profiles;
create trigger profile_rules_guard before insert or update on public.profiles
for each row execute function public.tg_profile_rules_guard();

revoke all on function public.my_house_rules() from public, anon;
revoke all on function public.accept_house_rules() from public, anon;
grant execute on function public.my_house_rules() to authenticated;
grant execute on function public.accept_house_rules() to authenticated;
