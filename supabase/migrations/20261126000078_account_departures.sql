-- Who left Based: a record of deleted accounts, shown on the owner's admin page ("Left Based").
--  * From now on, every deleted account is logged (name, email, city, when they joined, when they left),
--    however it's deleted: from the app, or from the Supabase dashboard.
--  * Accounts deleted before this existed are recovered from Supabase's sign-in log: anyone who ever
--    signed up or logged in but no longer has an account. Those rows have no name or city (it was erased
--    with the account) and show the last time they logged in instead of when they left.
--  * Only the owner can read any of it.

create table if not exists public.account_deletions (
  id          bigserial primary key,
  user_id     uuid not null,
  email       text,
  name        text,
  city        text,
  joined_at   timestamptz,
  deleted_at  timestamptz not null default now()
);
alter table public.account_deletions enable row level security;  -- no policies: owner reads through admin_departures()
revoke all on public.account_deletions from anon, authenticated;

create or replace function public.tg_log_account_deletion()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  insert into public.account_deletions (user_id, email, name, city, joined_at)
  select old.id, old.email, p.display_name, p.city, old.created_at
  from (select 1) x
  left join public.profiles p on p.id = old.id;
  return old;
exception when others then
  return old;  -- never block a deletion because the log failed
end $$;

drop trigger if exists log_account_deletion on auth.users;
create trigger log_account_deletion before delete on auth.users
for each row execute function public.tg_log_account_deletion();

create or replace function public.admin_departures()
returns jsonb language plpgsql stable security definer set search_path = public, auth as $$
declare
  v_logged jsonb;
  v_older  jsonb := '[]'::jsonb;
begin
  perform require_admin();

  select coalesce(jsonb_agg(jsonb_build_object(
           'at', d.deleted_at, 'email', d.email, 'name', d.name, 'city', d.city,
           'joined', d.joined_at, 'source', 'deleted') order by d.deleted_at desc), '[]'::jsonb)
    into v_logged
  from (select * from account_deletions order by deleted_at desc limit 100) d;

  begin
    select coalesce(jsonb_agg(jsonb_build_object(
             'at', s.last_seen, 'email', s.email, 'joined', s.first_seen, 'source', 'sign-in log')
             order by s.last_seen desc), '[]'::jsonb)
      into v_older
    from (
      select lower(a.payload->>'actor_username') as email,
             min(a.created_at) as first_seen, max(a.created_at) as last_seen
      from auth.audit_log_entries a
      where a.payload->>'actor_username' like '%@%'
      group by 1
    ) s
    where not exists (select 1 from auth.users u where lower(u.email) = s.email)
      and not exists (select 1 from account_deletions d where lower(d.email) = s.email);
  exception when others then
    v_older := '[]'::jsonb;  -- sign-in log unavailable: show only the logged deletions
  end;

  return jsonb_build_object('logged', v_logged, 'older', v_older);
end $$;

revoke all on function public.admin_departures() from public, anon;
grant execute on function public.admin_departures() to authenticated;
