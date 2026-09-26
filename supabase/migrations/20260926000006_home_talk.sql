-- =====================================================================
-- Based Dating v1 — data for the Home ("Your day") and Talk screens
-- Adds: who sent the last message, and the next open call per match.
-- =====================================================================
drop function if exists public.get_my_matches();

create function public.get_my_matches()
returns table (
  match_id uuid, other_id uuid, other_name text, other_photo text,
  created_at timestamptz, call_deadline timestamptz, max_deadline timestamptz,
  reschedules_left int, call_done boolean, video_call_done boolean,
  contact_unlocked boolean, icebreaker text, last_message text, last_message_at timestamptz,
  last_from_me boolean, next_call_at timestamptz, next_call_status text, next_call_kind text)
language sql stable security definer set search_path = public as $$
  select m.id, o.id, o.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'),
         m.created_at, m.call_deadline, m.max_deadline, 2 - m.reschedules_used,
         m.call_done, m.video_call_done, m.contact_unlocked, m.icebreaker,
         lm.body, lm.created_at, lm.sender_id = auth.uid(),
         nc.scheduled_for, nc.status, nc.kind
  from matches m
  join profiles o on o.id = case when m.user_a = auth.uid() then m.user_b else m.user_a end
  left join lateral (
    select x.body, x.created_at, x.sender_id from messages x
    where x.match_id = m.id and (x.status = 'sent' or x.sender_id = auth.uid())
    order by x.created_at desc limit 1) lm on true
  left join lateral (
    select c.scheduled_for, c.status, c.kind from calls c
    where c.match_id = m.id and c.status in ('proposed','accepted')
    order by c.scheduled_for limit 1) nc on true
  where auth.uid() in (m.user_a, m.user_b) and m.status = 'active'
  order by coalesce(lm.created_at, m.created_at) desc;
$$;

revoke all on function public.get_my_matches() from public, anon;
grant execute on function public.get_my_matches() to authenticated;
