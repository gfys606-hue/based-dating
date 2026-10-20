-- Voice notes replace video calls on the dating side (priority 2, Oct 19 2026).
--  * Days 0-3 of a match: voice notes are optional, texting is open.
--  * Day 3: a reminder. Then 24 more hours of texting.
--  * Day 4 on: if you haven't BOTH sent a voice note, texting locks; only voice notes can be sent.
--    No expiry: the chat just waits until the swap happens.
--  * Once both have sent one, the swap counts as the "call": phone numbers unlock and the match is "talked".
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Messages can be voice notes
-- ---------------------------------------------------------------------
alter table public.messages add column if not exists kind text not null default 'text';
alter table public.messages drop constraint if exists messages_kind_check;
alter table public.messages add constraint messages_kind_check check (kind in ('text','voice'));
alter table public.messages add column if not exists audio_path text;
alter table public.messages add column if not exists duration_ms int check (duration_ms is null or duration_ms between 0 and 120000);

alter table public.matches add column if not exists voice_swapped_at timestamptz;
alter table public.matches add column if not exists voice_reminded boolean not null default false;
alter table public.matches add column if not exists voice_lock_noticed boolean not null default false;

-- The window is now "4 days until texting locks" (3 free days + 24h after the reminder).
-- call_deadline keeps its name so the app's countdowns keep working.
alter table public.matches alter column call_deadline set default (now() + interval '4 days');
update public.matches set call_deadline = created_at + interval '4 days'
 where status = 'active' and not call_done;
-- matches that already had their call count as swapped (texting never locks for them)
update public.matches set voice_swapped_at = coalesce(call_completed_at, now())
 where call_done and voice_swapped_at is null;

-- ---------------------------------------------------------------------
-- Private storage: only the two people in the match can hear it
-- path = <match_id>/<sender_id>/<file>
-- ---------------------------------------------------------------------
create or replace function public.in_match(p_match text, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from matches m
                  where m.id::text = p_match and p_user in (m.user_a, m.user_b));
$$;
revoke all on function public.in_match(text, uuid) from public, anon;
grant execute on function public.in_match(text, uuid) to authenticated;

insert into storage.buckets (id, name, public) values ('voice-notes', 'voice-notes', false) on conflict (id) do nothing;
drop policy if exists "voice notes read" on storage.objects;
create policy "voice notes read" on storage.objects for select to authenticated
  using (bucket_id = 'voice-notes' and public.in_match((storage.foldername(name))[1]));
drop policy if exists "voice notes upload" on storage.objects;
create policy "voice notes upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'voice-notes'
              and public.in_match((storage.foldername(name))[1])
              and (storage.foldername(name))[2] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- Sending: the text lock, voice checks, and the contact filter
-- ---------------------------------------------------------------------
create or replace function public.tg_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m       matches;
  kinds   text[];
  blocked text[];
begin
  select * into m from matches where id = new.match_id;
  if m.id is null or new.sender_id not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then raise exception 'This match has ended'; end if;
  if (select status from profiles where id = new.sender_id) <> 'active' then raise exception 'Account not active'; end if;

  if new.kind = 'voice' then
    if new.audio_path is null or new.audio_path not like m.id::text || '/' || new.sender_id::text || '/%' then
      raise exception 'That voice note didn''t upload. Try again.';
    end if;
    new.body := 'Voice note';
    return new;
  end if;
  new.audio_path := null;
  new.duration_ms := null;

  -- day 4 on, no swap yet: only voice notes
  if m.voice_swapped_at is null and now() >= m.created_at + interval '4 days' then
    raise exception 'Texting is paused until you both send a voice note.';
  end if;

  kinds := detect_contact(new.body);
  if m.contact_unlocked then
    blocked := array(select unnest(kinds) except select 'phone');  -- phone numbers OK after unlock
  else
    blocked := kinds;
  end if;

  if cardinality(blocked) > 0 then
    new.status := 'blocked';
    new.block_reason := array_to_string(blocked, ',');
    perform penalize(new.sender_id, 'contact_violation', 0.02, m.id);
    perform notify(new.sender_id, 'message_blocked',
      case when m.contact_unlocked
        then 'Links and social handles can''t be shared. Phone numbers are fine.'
        else 'Numbers unlock once you''ve both sent a voice note.' end);
  end if;
  return new;
end $$;

-- Both sent a voice note: the swap is done, numbers unlock
create or replace function public.tg_message_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare m matches;
begin
  if new.status <> 'sent' then return null; end if;
  select * into m from matches where id = new.match_id;
  if new.kind = 'voice' and m.voice_swapped_at is null
     and exists (select 1 from messages where match_id = m.id and sender_id = m.user_a and kind = 'voice' and status = 'sent')
     and exists (select 1 from messages where match_id = m.id and sender_id = m.user_b and kind = 'voice' and status = 'sent') then
    update matches
       set voice_swapped_at = now(), call_done = true, call_completed_at = coalesce(call_completed_at, now()),
           contact_unlocked = true
     where id = m.id;
    perform notify(m.user_a, 'contact_unlocked', 'Voice notes swapped. You can share numbers now.');
    perform notify(m.user_b, 'contact_unlocked', 'Voice notes swapped. You can share numbers now.');
  end if;
  update profiles set last_active_at = now() where id = new.sender_id;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Matches no longer expire. Hourly: day-3 reminder, day-4 "texting paused" notice.
-- ---------------------------------------------------------------------
create or replace function public.expire_matches()
returns int language plpgsql security definer set search_path = public as $$
declare
  m matches;
  n int := 0;
  u uuid;
begin
  for m in select * from matches
            where status = 'active' and voice_swapped_at is null and not voice_reminded
              and now() >= created_at + interval '3 days' loop
    foreach u in array array[m.user_a, m.user_b] loop
      if not exists (select 1 from messages where match_id = m.id and sender_id = u and kind = 'voice' and status = 'sent') then
        perform notify(u, 'voice_reminder', 'Send a voice note. Texting pauses in 24 hours until you''ve both sent one.');
      end if;
    end loop;
    update matches set voice_reminded = true where id = m.id;
    n := n + 1;
  end loop;

  for m in select * from matches
            where status = 'active' and voice_swapped_at is null and not voice_lock_noticed
              and now() >= created_at + interval '4 days' loop
    foreach u in array array[m.user_a, m.user_b] loop
      perform notify(u, 'voice_reminder', 'Texting is paused. Send a voice note to keep talking.');
    end loop;
    update matches set voice_lock_noticed = true where id = m.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the hourly job already calls expire_matches(); fine for the reminders
-- ---------------------------------------------------------------------
-- New-match notice
-- ---------------------------------------------------------------------
create or replace function public.like_user(p_target uuid)
returns uuid   -- match id if it's mutual, else null
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_match uuid;
begin
  if (select status from profiles where id = me) <> 'active' then raise exception 'Account not active'; end if;
  if effective_tier(me) = 'invisible' then raise exception 'Account not active'; end if;
  if not coalesce((select dating_on from profiles where id = me), false) then raise exception 'Turn on dating first.'; end if;
  if not coalesce((select dating_on from profiles where id = p_target), false) then raise exception 'They aren''t dating right now.'; end if;
  if (select count(*) from likes where from_user = me and created_at > now() - interval '1 day')
   + (select count(*) from passes where from_user = me and created_at > now() - interval '1 day') >= daily_pick_cap(me) then
    raise exception 'Daily limit reached. New matches tomorrow.';
  end if;

  insert into likes (from_user, to_user) values (me, p_target) on conflict do nothing;

  if exists (select 1 from likes where from_user = p_target and to_user = me)
     and (select status from profiles where id = p_target) = 'active' then
    insert into matches (user_a, user_b, icebreaker)
    values (least(me, p_target), greatest(me, p_target), make_icebreaker(me, p_target))
    on conflict (user_a, user_b) do nothing
    returning id into v_match;

    if v_match is not null then
      perform notify(p_target, 'match', 'New match. Swap voice notes to unlock numbers.');
      perform notify(me,       'match', 'New match. Swap voice notes to unlock numbers.');
    end if;
  end if;
  return v_match;
end $$;

-- ---------------------------------------------------------------------
-- Match list: who has sent a voice note, and when texting locks
-- ---------------------------------------------------------------------
drop function if exists public.get_my_matches();
create function public.get_my_matches()
returns table (
  match_id uuid, other_id uuid, other_name text, other_photo text,
  created_at timestamptz, call_deadline timestamptz, max_deadline timestamptz,
  reschedules_left int, call_done boolean, video_call_done boolean,
  contact_unlocked boolean, icebreaker text, last_message text, last_message_at timestamptz,
  last_from_me boolean, next_call_at timestamptz, next_call_status text, next_call_kind text,
  voice_mine boolean, voice_theirs boolean, voice_swapped boolean, text_locked boolean)
language sql stable security definer set search_path = public as $$
  select m.id, o.id, o.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'),
         m.created_at, m.created_at + interval '4 days', m.max_deadline, 2 - m.reschedules_used,
         m.call_done, m.video_call_done, m.contact_unlocked, m.icebreaker,
         lm.body, lm.created_at, lm.sender_id = auth.uid(),
         null::timestamptz, null::text, null::text,
         exists (select 1 from messages v where v.match_id = m.id and v.sender_id = auth.uid() and v.kind = 'voice' and v.status = 'sent'),
         exists (select 1 from messages v where v.match_id = m.id and v.sender_id = o.id and v.kind = 'voice' and v.status = 'sent'),
         m.voice_swapped_at is not null,
         m.voice_swapped_at is null and now() >= m.created_at + interval '4 days'
  from matches m
  join profiles o on o.id = case when m.user_a = auth.uid() then m.user_b else m.user_a end
  left join lateral (
    select x.body, x.created_at, x.sender_id from messages x
    where x.match_id = m.id and (x.status = 'sent' or x.sender_id = auth.uid())
    order by x.created_at desc limit 1) lm on true
  where auth.uid() in (m.user_a, m.user_b) and m.status = 'active'
  order by coalesce(lm.created_at, m.created_at) desc;
$$;

revoke all on function public.get_my_matches() from public, anon;
grant execute on function public.get_my_matches() to authenticated;
revoke all on function public.like_user(uuid) from public, anon;
grant execute on function public.like_user(uuid) to authenticated;
