-- Owner notifications for new accounts and deleted accounts (show under "Heads up", and push if it's on).
--  * New account: sent when someone finishes the first sign-up step (name + birthday), with their name and email.
--  * Deleted account: sent when an account is deleted (from the app or the Supabase dashboard), with name,
--    email and city. Builds on the deletion log in 20261126000078_account_departures.sql — run that first.
--  * Your own account never triggers either one.

create or replace function public.tg_owner_new_account()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_owner uuid;
  v_email text;
begin
  if coalesce(new.is_admin, false) then return new; end if;
  select email into v_email from auth.users where id = new.id;
  for v_owner in select id from profiles where is_admin and status <> 'banned' and id <> new.id loop
    perform notify(v_owner, 'new_account',
      'New account: ' || coalesce(nullif(trim(new.display_name), ''), 'someone') ||
      coalesce(' (' || v_email || ')', '') || ' just joined Based.');
  end loop;
  return new;
exception when others then
  return new;  -- never block a sign-up because the notice failed
end $$;

drop trigger if exists owner_new_account on public.profiles;
create trigger owner_new_account after insert on public.profiles
for each row execute function public.tg_owner_new_account();

-- Deletion log + owner notice
create or replace function public.tg_log_account_deletion()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare
  v_owner uuid;
  v_name  text;
  v_city  text;
  v_admin boolean;
begin
  select p.display_name, p.city, coalesce(p.is_admin, false) into v_name, v_city, v_admin
  from public.profiles p where p.id = old.id;

  insert into public.account_deletions (user_id, email, name, city, joined_at)
  values (old.id, old.email, v_name, v_city, old.created_at);

  if not coalesce(v_admin, false) then
    for v_owner in select id from public.profiles where is_admin and status <> 'banned' and id <> old.id loop
      perform public.notify(v_owner, 'account_deleted',
        coalesce(nullif(trim(v_name), ''), 'Someone') ||
        coalesce(' (' || old.email || ')', '') ||
        coalesce(' in ' || initcap(v_city), '') || ' deleted their account.');
    end loop;
  end if;
  return old;
exception when others then
  return old;  -- never block a deletion because the log or notice failed
end $$;
