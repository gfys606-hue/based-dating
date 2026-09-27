-- Account deletion (required by Google Play and Apple).
-- The app first removes the user's own files from storage, then calls delete_my_account().
-- Deleting the auth user cascades to profiles and everything that references it.

-- calls.proposed_by had no ON DELETE rule, which would block deleting someone who proposed a call.
alter table public.calls drop constraint if exists calls_proposed_by_fkey;
alter table public.calls
  add constraint calls_proposed_by_fkey
  foreign key (proposed_by) references public.profiles(id) on delete cascade;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = uid;
end $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
