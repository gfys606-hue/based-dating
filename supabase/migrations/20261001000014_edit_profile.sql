-- Edit profile: delete, replace and reorder photos without ever dropping below the
-- 3 clear face shots in slots 1-3 (and without a brief "account paused" blip).
--   * slots 1-3 can be replaced or reordered, never deleted
--   * slots 4-6 can be deleted; later photos shift up to fill the gap
--   * a photo moved into slots 1-3 that hasn't passed the clear-face check is re-checked

-- Let a reorder swap positions inside one statement/transaction.
alter table public.photos drop constraint if exists photos_user_id_position_key;
do $$ begin
  alter table public.photos add constraint photos_user_position unique (user_id, position) deferrable initially immediate;
exception when duplicate_object or duplicate_table then null; end $$;

-- Delete one of photos 4-6. Returns its storage path so the app can remove the file.
create or replace function public.delete_photo(p_photo uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ph photos;
begin
  select * into ph from photos where id = p_photo and user_id = me;
  if ph.id is null then raise exception 'Photo not found'; end if;
  if ph.position <= 3 then raise exception 'Photos 1–3 can be replaced, not deleted.'; end if;

  set constraints photos_user_position deferred;
  delete from photos where id = ph.id;
  update photos set position = position - 1 where user_id = me and position > ph.position;
  return ph.storage_path;
end $$;

-- Reorder: p_ids lists ALL of the user's photos in their new order (first = slot 1).
-- Returns the ids that need a fresh photo check (moved into slots 1-3 without a passed clear-face check).
create or replace function public.reorder_photos(p_ids uuid[])
returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  n int;
  recheck uuid[] := '{}';
  i int;
  ph photos;
begin
  select count(*) into n from photos where user_id = me;
  if cardinality(p_ids) <> n
     or (select count(*) from photos where user_id = me and id = any(p_ids)) <> n then
    raise exception 'Reorder must include each of your photos once.';
  end if;

  set constraints photos_user_position deferred;
  for i in 1 .. n loop
    select * into ph from photos where id = p_ids[i];
    if i <= 3 and ph.position > 3 and coalesce(ph.clear_face, false) = false then
      update photos set position = i, review_status = 'pending', shows_user = null, clear_face = null, reject_reason = null
      where id = ph.id;
      recheck := array_append(recheck, ph.id);
    else
      update photos set position = i where id = ph.id;
    end if;
  end loop;
  return recheck;
end $$;

revoke all on function public.delete_photo(uuid) from public, anon;
grant execute on function public.delete_photo(uuid) to authenticated;
revoke all on function public.reorder_photos(uuid[]) from public, anon;
grant execute on function public.reorder_photos(uuid[]) to authenticated;
