-- =====================================================================
-- Based Dating v1 — core rules
--  * distance-block match batches + hidden desirability + engagement tiers
--  * likes / matches / "Not feeling it"
--  * 3-day call window, 5-min minimum, 2 shared reschedules
--  * contact filter + phone unlock (video call + 1 message each)
--  * photo rules / account pause
--  * hidden engagement score, 2 nudges, then gradual invisibility
-- =====================================================================

create table public.impressions (
  viewer     uuid references public.profiles(id) on delete cascade,
  shown      uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (viewer, shown)
);

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.haversine_km(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable as $$
  select 6371 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- Distance blocks: 10 → 15 → 25 → 50 → 100 → 250 → 500 km
create or replace function public.distance_block(km float8)
returns int language sql immutable as $$
  select case
    when km <= 10  then 10
    when km <= 15  then 15
    when km <= 25  then 25
    when km <= 50  then 50
    when km <= 100 then 100
    when km <= 250 then 250
    when km <= 500 then 500
    else null end;
$$;

-- Effective tier: new accounts (first 7 days) are always treated as healthy
create or replace function public.effective_tier(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when p.created_at > now() - interval '7 days' then 'healthy'
    else coalesce(s.tier, 'healthy') end
  from profiles p left join user_scores s on s.user_id = p.id
  where p.id = p_user;
$$;

create or replace function public.penalize(p_user uuid, p_kind text, p_weight real, p_match uuid default null)
returns void language sql security definer set search_path = public as $$
  insert into engagement_events (user_id, kind, weight, match_id) values (p_user, p_kind, p_weight, p_match);
$$;

create or replace function public.notify(p_user uuid, p_kind text, p_body text)
returns void language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body) values (p_user, p_kind, p_body);
$$;

create or replace function public.other_user(m public.matches, me uuid)
returns uuid language sql immutable as $$
  select case when m.user_a = me then m.user_b else m.user_a end;
$$;

-- New profile => hidden score row
create or replace function public.tg_profile_created()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into user_scores (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;

create trigger profile_created after insert on public.profiles
for each row execute function public.tg_profile_created();

-- Clients may not change their own status / verification flags directly
create or replace function public.tg_profile_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    new.status          := old.status;
    new.pause_reason    := old.pause_reason;
    new.selfie_verified := old.selfie_verified;
    new.ad_free         := old.ad_free;
    new.created_at      := old.created_at;
  end if;
  return new;
end $$;

create trigger profile_guard before update on public.profiles
for each row execute function public.tg_profile_guard();

-- ---------------------------------------------------------------------
-- Photo rules
--   * photos 1-3: user alone, facing camera, clear face, matches selfie
--   * photos 4-6: looser, but the user must be in them
--   * anything else => account paused until fixed
-- ---------------------------------------------------------------------
create or replace function public.photo_problem(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from photos where user_id = p_user and review_status = 'rejected')
      then 'A photo doesn''t clearly show you. Replace it to continue.'
    when (select count(*) from photos
          where user_id = p_user and position between 1 and 3
            and review_status = 'approved' and shows_user and clear_face) < 3
      then 'You need 3 clear photos of your face, looking at the camera.'
    else null end;
$$;

create or replace function public.refresh_photo_status(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_problem text := photo_problem(p_user);
  v_status  text;
  v_reason  text;
  v_pending int;
begin
  select status, pause_reason into v_status, v_reason from profiles where id = p_user;
  select count(*) into v_pending from photos where user_id = p_user and review_status = 'pending';

  if v_status = 'active' and v_problem is not null and v_pending = 0 then
    update profiles set status = 'paused', pause_reason = v_problem where id = p_user;
    perform notify(p_user, 'paused', v_problem);
  elsif v_status = 'active' and exists (select 1 from photos where user_id = p_user and review_status = 'rejected') then
    update profiles set status = 'paused', pause_reason = v_problem where id = p_user;
    perform notify(p_user, 'paused', v_problem);
  elsif v_status = 'paused' and v_problem is null
        and v_reason in ('A photo doesn''t clearly show you. Replace it to continue.',
                             'You need 3 clear photos of your face, looking at the camera.') then
    update profiles set status = 'active', pause_reason = null where id = p_user;
    perform notify(p_user, 'unpaused', 'Your photos are approved. You''re visible again.');
  end if;
end $$;

create or replace function public.tg_photos_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform refresh_photo_status(coalesce(new.user_id, old.user_id));
  return null;
end $$;

create trigger photos_changed after insert or update or delete on public.photos
for each row execute function public.tg_photos_changed();

-- Clients can't set review fields; only the photo-check function (service role) can
create or replace function public.tg_photo_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    new.review_status := 'pending';
    new.shows_user    := null;
    new.clear_face    := null;
    new.reject_reason := null;
  end if;
  return new;
end $$;

create trigger photo_guard before insert or update on public.photos
for each row execute function public.tg_photo_guard();

-- Called by the photo-check edge function after AI review
create or replace function public.set_photo_review(p_photo uuid, p_shows_user boolean, p_clear_face boolean, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_pos int;
begin
  select position into v_pos from photos where id = p_photo;
  update photos set
    shows_user    = p_shows_user,
    clear_face    = p_clear_face,
    review_status = case
      when not p_shows_user then 'rejected'
      when v_pos <= 3 and not p_clear_face then 'rejected'
      else 'approved' end,
    reject_reason = case
      when not p_shows_user then coalesce(p_reason, 'This photo needs to show you.')
      when v_pos <= 3 and not p_clear_face then coalesce(p_reason, 'Photos 1-3 must show your face clearly, looking at the camera.')
      else null end
  where id = p_photo;
end $$;

-- Onboarding finish: selfie verified, 3 clear photos, 5+ interests, location
create or replace function public.complete_onboarding()
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p  profiles;
begin
  select * into p from profiles where id = me;
  if p.id is null then raise exception 'No profile'; end if;
  if p.status <> 'onboarding' then return p.status; end if;
  if not p.selfie_verified then raise exception 'Selfie check not complete'; end if;
  if photo_problem(me) is not null then raise exception '%', photo_problem(me); end if;
  if (select count(*) from user_topics where user_id = me) < 5 then raise exception 'Pick at least 5 interests'; end if;
  if p.lat is null then raise exception 'Location is required'; end if;
  update profiles set status = 'active' where id = me;
  return 'active';
end $$;

-- ---------------------------------------------------------------------
-- Match batch (daily, deliberate — not endless swiping)
-- ---------------------------------------------------------------------

create or replace function public.get_match_batch(p_limit int default 10)
returns table (
  user_id uuid, display_name text, age int, distance_km int,
  shared_topics text[], photo_paths text[]
)
language plpgsql security definer set search_path = public as $$
declare
  me       uuid := auth.uid();
  v        profiles;
  v_tier   text;
  v_des    real;
  v_acted  int;
  v_cap    constant int := 25;
begin
  select * into v from profiles where id = me;
  if v.id is null or v.status <> 'active' or v.lat is null then return; end if;

  v_tier := effective_tier(me);
  if v_tier = 'invisible' then return; end if;

  select count(*) into v_acted from (
    select 1 from likes  where from_user = me and created_at > now() - interval '1 day'
    union all
    select 1 from passes where from_user = me and created_at > now() - interval '1 day') x;
  if v_acted >= v_cap then return; end if;

  select s.desirability into v_des from user_scores s where s.user_id = me;

  create temp table if not exists _batch (
    user_id uuid, display_name text, age int, distance_km int,
    shared_topics text[], photo_paths text[], rn bigint) on commit drop;
  truncate _batch;

  insert into _batch
  with cand as (
    select c.id, c.display_name, c.birthdate,
           haversine_km(v.lat, v.lng, c.lat, c.lng) as km,
           effective_tier(c.id) as tier,
           abs(coalesce(s.desirability, 0.5) - coalesce(v_des, 0.5)) as gap
    from profiles c
    left join user_scores s on s.user_id = c.id
    where c.id <> me
      and c.status = 'active'
      and c.lat is not null
      and c.gender = any (v.seeking)
      and v.gender = any (c.seeking)
      and not exists (select 1 from likes  l where l.from_user = me and l.to_user = c.id)
      and not exists (select 1 from passes p where p.from_user = me and p.to_user = c.id)
      and not exists (select 1 from matches m where m.user_a = least(me, c.id) and m.user_b = greatest(me, c.id))
      and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = c.id) or (b.blocker = c.id and b.blocked = me))
  ),
  scored as (
    select cand.*,
           distance_block(km) as blk,
           (select coalesce(array_agg(t.name order by t.name), '{}')
              from user_topics a join user_topics b on a.topic_id = b.topic_id and b.user_id = cand.id
              join topics t on t.id = a.topic_id
             where a.user_id = me) as shared
    from cand
    where distance_block(km) is not null
      and tier <> 'invisible'
      and ((v_tier = 'low' and tier in ('low','slipping'))
        or (v_tier <> 'low' and tier in ('healthy','slipping')))
  ),
  ranked as (
    select scored.*,
           row_number() over (order by
             blk,
             case tier when 'healthy' then 0 when 'slipping' then 1 else 2 end,
             case when blk = 10 then -cardinality(shared) else 0 end,
             km * (1 + 2 * gap)) as rn
    from scored
  )
  select r.id, r.display_name,
         extract(year from age(r.birthdate))::int,
         greatest(1, round(r.km))::int,
         r.shared,
         (select coalesce(array_agg(ph.storage_path order by ph.position), '{}')
            from photos ph where ph.user_id = r.id and ph.review_status = 'approved'),
         r.rn
  from ranked r
  where r.rn <= least(p_limit, v_cap - v_acted);

  insert into impressions (viewer, shown)
  select me, b.user_id from _batch b
  on conflict do nothing;

  return query
    select b.user_id, b.display_name, b.age, b.distance_km, b.shared_topics, b.photo_paths
    from _batch b order by b.rn;
end $$;

-- ---------------------------------------------------------------------
-- Like / pass / match
-- ---------------------------------------------------------------------
create or replace function public.make_icebreaker(a uuid, b uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select format('You both follow %s. What got you into it?', t.name)
       from user_topics x join user_topics y on x.topic_id = y.topic_id and y.user_id = b
       join topics t on t.id = x.topic_id
      where x.user_id = a order by random() limit 1),
    'What''s something you''re into right now that most people wouldn''t guess?');
$$;

create or replace function public.like_user(p_target uuid)
returns uuid   -- match id if it's mutual, else null
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_match uuid;
begin
  if (select status from profiles where id = me) <> 'active' then raise exception 'Account not active'; end if;
  if effective_tier(me) = 'invisible' then raise exception 'Account not active'; end if;
  if (select count(*) from likes where from_user = me and created_at > now() - interval '1 day')
   + (select count(*) from passes where from_user = me and created_at > now() - interval '1 day') >= 25 then
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
      perform notify(p_target, 'match', 'New match. You have 3 days to get a call in.');
      perform notify(me,       'match', 'New match. You have 3 days to get a call in.');
    end if;
  end if;
  return v_match;
end $$;

create or replace function public.pass_user(p_target uuid)
returns void language sql security definer set search_path = public as $$
  insert into passes (from_user, to_user) values (auth.uid(), p_target) on conflict do nothing;
$$;

-- "Not feeling it" / delete conversation — never penalized
create or replace function public.end_match(p_match uuid, p_reason text default 'not_feeling_it')
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  matches;
begin
  select * into m from matches where id = p_match;
  if m.id is null or me not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then return; end if;
  if p_reason not in ('not_feeling_it','deleted') then raise exception 'Invalid reason'; end if;

  update matches set status = 'ended', ended_by = me, end_reason = p_reason, ended_at = now()
  where id = p_match;
  update calls set status = 'cancelled' where match_id = p_match and status in ('proposed','accepted');

  perform notify(other_user(m, me), 'match_ended',
    'Your match ended the conversation. No hard feelings — new matches are on the way.');
end $$;

-- ---------------------------------------------------------------------
-- Calls: 3-day window, 5-minute minimum, 2 shared reschedules
-- ---------------------------------------------------------------------
create or replace function public.propose_call(p_match uuid, p_when timestamptz, p_kind text default 'voice')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  matches;
  v_id uuid;
begin
  select * into m from matches where id = p_match;
  if m.id is null or me not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then raise exception 'Match has ended'; end if;
  if p_when < now() - interval '5 minutes' then raise exception 'Pick a future time'; end if;
  if not m.call_done and p_when > m.call_deadline then
    raise exception 'The call has to happen before %', m.call_deadline;
  end if;

  update calls set status = 'cancelled' where match_id = p_match and status = 'proposed';
  insert into calls (match_id, proposed_by, kind, scheduled_for)
  values (p_match, me, p_kind, p_when) returning id into v_id;

  perform notify(other_user(m, me), 'call_proposed', 'Your match proposed a call time.');
  return v_id;
end $$;

create or replace function public.accept_call(p_call uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c  calls;
  m  matches;
begin
  select * into c from calls where id = p_call;
  select * into m from matches where id = c.match_id;
  if me not in (m.user_a, m.user_b) or me = c.proposed_by then raise exception 'Only your match can accept'; end if;
  if c.status <> 'proposed' then raise exception 'Call is no longer open'; end if;
  update calls set status = 'accepted' where id = p_call;
  perform notify(c.proposed_by, 'call_accepted', 'Call confirmed.');
end $$;

-- Moving a call uses 1 of the match's 2 shared reschedules and can push
-- the deadline past day 3 by at most 48 hours.
create or replace function public.request_reschedule(p_match uuid, p_new_time timestamptz, p_kind text default 'voice')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m  matches;
  v_id uuid;
begin
  select * into m from matches where id = p_match for update;
  if m.id is null or me not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then raise exception 'Match has ended'; end if;
  if m.reschedules_used >= 2 then raise exception 'No reschedules left for this match'; end if;
  if p_new_time > m.max_deadline then raise exception 'Latest possible time is %', m.max_deadline; end if;

  update matches set
    reschedules_used = reschedules_used + 1,
    call_deadline    = least(max_deadline, greatest(call_deadline, p_new_time + interval '1 hour'))
  where id = p_match;

  update calls set status = 'cancelled' where match_id = p_match and status in ('proposed','accepted');
  insert into calls (match_id, proposed_by, kind, scheduled_for)
  values (p_match, me, p_kind, p_new_time) returning id into v_id;

  perform notify(other_user(m, me), 'call_rescheduled', 'Your match moved the call. Tap to confirm the new time.');
  return v_id;
end $$;

-- Called by the call provider webhook (service role only).
--   5+ min            => counts; video also sets video_call_done
--   < 5 min, early    => uses a reschedule; out of reschedules ends the match
--   < 5 min, report   => free, no penalty for the reporter
--   < 5 min, connection => free
create or replace function public.complete_call(
  p_call uuid, p_kind text, p_duration_seconds int, p_ended_by uuid, p_end_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare
  c calls;
  m matches;
begin
  select * into c from calls where id = p_call for update;
  select * into m from matches where id = c.match_id for update;
  if c.id is null then raise exception 'No such call'; end if;

  update calls set kind = p_kind, duration_seconds = p_duration_seconds, ended_by = p_ended_by,
                   end_reason = p_end_reason, ended_at = now(),
                   started_at = now() - make_interval(secs => p_duration_seconds),
                   status = case when p_duration_seconds >= 300 then 'completed' else 'short' end
  where id = p_call;

  if p_duration_seconds >= 300 then
    update matches set
      call_done         = true,
      video_call_done   = video_call_done or p_kind = 'video',
      call_completed_at = case when p_kind = 'video' then now() else coalesce(call_completed_at, now()) end
    where id = m.id;
    return 'counted';
  end if;

  if p_end_reason in ('report','connection') then
    return 'free_retry';
  end if;

  -- early hang-up: uses a shared reschedule
  if p_ended_by is not null then
    perform penalize(p_ended_by, 'early_hangup', 0.03, m.id);
  end if;

  if m.call_done then
    return 'short_after_call';          -- match already alive; nothing to lose
  elsif m.reschedules_used >= 2 then
    update matches set status = 'ended', end_reason = 'reschedules_exhausted', ended_at = now(), ended_by = p_ended_by
    where id = m.id;
    if p_ended_by is not null then perform penalize(p_ended_by, 'reschedules_exhausted', 0.08, m.id); end if;
    return 'match_ended';
  else
    update matches set reschedules_used = reschedules_used + 1,
                       call_deadline = least(max_deadline, call_deadline + interval '24 hours')
    where id = m.id;
    return 'reschedule_used';
  end if;
end $$;

-- No-show (service role / scheduler). If both missed, the match is deleted.
create or replace function public.mark_no_show(p_call uuid, p_no_show uuid, p_both boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare
  c calls;
  m matches;
begin
  select * into c from calls where id = p_call;
  select * into m from matches where id = c.match_id;
  update calls set status = 'missed', no_show_user = p_no_show where id = p_call;

  if p_both then
    update matches set status = 'ended', end_reason = 'no_show', ended_at = now() where id = m.id;
    perform penalize(m.user_a, 'no_show', 0.10, m.id);
    perform penalize(m.user_b, 'no_show', 0.10, m.id);
  else
    perform penalize(p_no_show, 'no_show', 0.15, m.id);
    perform notify(other_user(m, p_no_show), 'no_show',
      'Your match missed the call. You can end the match with no penalty, or give them another shot.');
  end if;
end $$;

-- Hourly: close matches whose window ran out with no call
create or replace function public.expire_matches()
returns int language plpgsql security definer set search_path = public as $$
declare
  m matches;
  n int := 0;
  u uuid;
begin
  for m in select * from matches where status = 'active' and not call_done and now() > call_deadline loop
    update matches set status = 'ended', end_reason = 'expired', ended_at = now() where id = m.id;
    -- whoever was unresponsive (no messages and never proposed a call) takes the hit
    foreach u in array array[m.user_a, m.user_b] loop
      if not exists (select 1 from messages where match_id = m.id and sender_id = u and status = 'sent')
         and not exists (select 1 from calls where match_id = m.id and proposed_by = u) then
        perform penalize(u, 'expired_unresponsive', 0.10, m.id);
      end if;
    end loop;
    perform notify(m.user_a, 'match_expired', 'A match expired — no call happened in time.');
    perform notify(m.user_b, 'match_expired', 'A match expired — no call happened in time.');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Messages: contact filter + phone unlock
-- ---------------------------------------------------------------------
create or replace function public.detect_contact(p_body text)
returns text[] language plpgsql immutable as $$
declare
  t text := lower(p_body);
  found text[] := '{}';
begin
  -- phone: 7+ digits with separators, or 7+ spelled-out digits
  if t ~ '(\+?\d[\s\-\.\(\)]*){7,}'
     or t ~ '((zero|oh|one|two|three|four|five|six|seven|eight|nine)[\s\-,\.]*){7,}' then
    found := array_append(found, 'phone');
  end if;
  if t ~ '[a-z0-9._%+\-]+\s*(@|\(at\)|\[at\])\s*[a-z0-9\-]+\s*(\.|\(dot\)|\[dot\]| dot )\s*[a-z]{2,}' then
    found := array_append(found, 'email');
  end if;
  if t ~ '(https?://|www\.)' or t ~ '\m[a-z0-9\-]+\.(com|ca|net|org|io|co|me|app|ly|gg|tv)\M' then
    found := array_append(found, 'link');
  end if;
  if t ~ '(^|\s)@[a-z0-9_.]{2,}'
     or t ~ '\m(insta|instagram|ig|snap|snapchat|sc|tiktok|telegram|whatsapp|kik|discord|fb|facebook|twitter|x)\M\s*(:|-|is|@)' then
    found := array_append(found, 'handle');
  end if;
  return found;
end $$;

create or replace function public.tg_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m     matches;
  kinds text[];
  blocked text[];
begin
  select * into m from matches where id = new.match_id;
  if m.id is null or new.sender_id not in (m.user_a, m.user_b) then raise exception 'Not your match'; end if;
  if m.status <> 'active' then raise exception 'This match has ended'; end if;
  if (select status from profiles where id = new.sender_id) <> 'active' then raise exception 'Account not active'; end if;

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
        else 'Contact info unlocks after a video call and one message from each of you.' end);
  end if;
  return new;
end $$;

create trigger message_before before insert on public.messages
for each row execute function public.tg_message_before();

-- After a completed video call, one message from each person unlocks phone numbers
create or replace function public.tg_message_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare m matches;
begin
  if new.status <> 'sent' then return null; end if;
  select * into m from matches where id = new.match_id;
  if m.video_call_done and not m.contact_unlocked
     and exists (select 1 from messages where match_id = m.id and sender_id = m.user_a
                   and status = 'sent' and created_at >= m.call_completed_at)
     and exists (select 1 from messages where match_id = m.id and sender_id = m.user_b
                   and status = 'sent' and created_at >= m.call_completed_at) then
    update matches set contact_unlocked = true where id = m.id;
    perform notify(m.user_a, 'contact_unlocked', 'You can now share phone numbers.');
    perform notify(m.user_b, 'contact_unlocked', 'You can now share phone numbers.');
  end if;
  update profiles set last_active_at = now() where id = new.sender_id;
  return null;
end $$;

create trigger message_after after insert on public.messages
for each row execute function public.tg_message_after();

-- ---------------------------------------------------------------------
-- Hidden engagement score (run hourly/daily via cron)
--   success : call done, or 3+ messages each way, or you politely ended it
--   excluded: they ignored you, they ended it, or it's still inside its window
--   failure : you let it sit
-- score = 0.60*conversation_rate + 0.25*effort_balance + 0.15*asks_questions − penalties
-- ---------------------------------------------------------------------
create or replace function public.compute_engagement(p_user uuid)
returns table (score real, judged int)
language sql stable security definer set search_path = public as $$
  with m as (
    select mt.*,
      (select count(*) from messages x where x.match_id = mt.id and x.sender_id = p_user and x.status = 'sent') as mine,
      (select count(*) from messages x where x.match_id = mt.id and x.sender_id <> p_user and x.status = 'sent') as theirs,
      (select avg(char_length(body)) from messages x where x.match_id = mt.id and x.sender_id = p_user and x.status = 'sent') as my_len,
      (select avg(char_length(body)) from messages x where x.match_id = mt.id and x.sender_id <> p_user and x.status = 'sent') as their_len,
      (select count(*) from messages x where x.match_id = mt.id and x.sender_id = p_user and x.status = 'sent' and x.body like '%?%') as my_q
    from matches mt
    where p_user in (mt.user_a, mt.user_b) and mt.created_at > now() - interval '30 days'
  ),
  judged as (
    select m.*,
      case
        when call_done or (mine >= 3 and theirs >= 3) then 'success'
        when status = 'ended' and end_reason = 'not_feeling_it' and ended_by = p_user then 'success'
        when mine >= 1 and theirs = 0 then 'excluded'
        when status = 'ended' and ended_by is not null and ended_by <> p_user then 'excluded'
        when status = 'active' and now() < call_deadline and mine > 0 then 'excluded'
        when status = 'active' and now() < created_at + interval '24 hours' then 'excluded'
        else 'failure' end as outcome
    from m
  ),
  agg as (
    select
      count(*) filter (where outcome = 'success')::real as s,
      count(*) filter (where outcome in ('success','failure'))::real as n,
      avg(least(1.0, my_len / nullif(their_len, 0))) filter (where mine > 0 and theirs > 0) as effort,
      avg(case when my_q > 0 then 1.0 else 0.0 end) filter (where mine >= 3) as asks
    from judged
  ),
  pen as (
    select least(0.6, coalesce(sum(weight), 0)) as p
    from engagement_events where user_id = p_user and created_at > now() - interval '30 days'
  )
  select
    -- someone who never writes back gets no free credit for effort/questions
    (0.60 * coalesce(agg.s / nullif(agg.n, 0), 1.0)
   + 0.25 * coalesce(agg.effort, agg.s / nullif(agg.n, 0), 1.0)
   + 0.15 * coalesce(agg.asks,   agg.s / nullif(agg.n, 0), 1.0)
   - pen.p)::real,
    agg.n::int
  from agg, pen;
$$;

create or replace function public.recompute_scores()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_score real; v_judged int;
  v_raw text; v_tier text;
  s user_scores;
  n int := 0;
  v_waiting int;
begin
  for r in select p.id, p.created_at from profiles p where p.status in ('active','paused') loop
    select * into v_score, v_judged from compute_engagement(r.id);
    select * into s from user_scores where user_id = r.id;

    v_raw := case
      when v_judged < 3 then 'healthy'
      when v_score >= 0.55 then 'healthy'
      when v_score >= 0.40 then 'slipping'
      when v_score >= 0.25 then 'low'
      else 'invisible' end;

    -- Gradual: move at most one step worse per run; recover one step per run
    v_tier := case
      when v_raw = s.tier then s.tier
      when array_position(array['healthy','slipping','low','invisible'], v_raw)
         > array_position(array['healthy','slipping','low','invisible'], s.tier)
        then (array['healthy','slipping','low','invisible'])[array_position(array['healthy','slipping','low','invisible'], s.tier) + 1]
      else (array['healthy','slipping','low','invisible'])[array_position(array['healthy','slipping','low','invisible'], s.tier) - 1]
    end;

    -- 1-2 nudges before any throttle kicks in
    if s.tier = 'healthy' and v_tier <> 'healthy' and s.nudges_sent < 2 then
      if s.last_nudged_at is null or s.last_nudged_at < now() - interval '2 days' then
        select count(*) into v_waiting from matches mt
         where r.id in (mt.user_a, mt.user_b) and mt.status = 'active'
           and not exists (select 1 from messages x where x.match_id = mt.id and x.sender_id = r.id);
        perform notify(r.id, 'nudge', format(
          'You have %s matches waiting on you. People who actually talk get seen more.', v_waiting));
        update user_scores set nudges_sent = nudges_sent + 1, last_nudged_at = now() where user_id = r.id;
      end if;
      v_tier := 'healthy';
    end if;

    update user_scores set
      engagement_score = v_score,
      tier = v_tier,
      nudges_sent = case when v_raw = 'healthy' then 0 else nudges_sent end,
      -- smoothed like-rate; starts neutral at 0.5 and adjusts as people react
      desirability = least(1.0, greatest(0.0,
        ((select count(*) from likes l where l.to_user = r.id) + 2.5)::real
        / ((select count(*) from impressions i where i.shown = r.id) + 5)::real)),
      computed_at = now()
    where user_id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
