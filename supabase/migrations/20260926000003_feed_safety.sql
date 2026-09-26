-- =====================================================================
-- Based Dating v1 — interest feed, profiles-as-activity, safety
-- =====================================================================

-- ---------------------------------------------------------------------
-- Feed
-- ---------------------------------------------------------------------
create table public.posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references public.profiles(id) on delete cascade,
  topic_id    int  not null references public.topics(id),
  kind        text not null check (kind in ('take','media','question','poll','repost')),
  body        text check (char_length(body) <= 500),
  media_path  text,
  poll_options text[],
  repost_of   uuid references public.posts(id) on delete set null,
  lat         double precision,   -- rounded to ~1 km on insert
  lng         double precision,
  status      text not null default 'visible' check (status in ('visible','blocked','removed')),
  created_at  timestamptz not null default now(),
  check (kind <> 'repost' or (repost_of is not null and char_length(coalesce(body,'')) > 0)),  -- reposts need your own comment
  check (kind <> 'poll' or cardinality(poll_options) between 2 and 4)
);

create table public.comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts(id) on delete cascade,
  author_id  uuid not null references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 500),
  status     text not null default 'visible' check (status in ('visible','blocked','hostile','removed')),
  created_at timestamptz not null default now()
);

create table public.reactions (
  post_id    uuid references public.posts(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.saves (
  post_id    uuid references public.posts(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.poll_votes (
  post_id  uuid references public.posts(id) on delete cascade,
  user_id  uuid references public.profiles(id) on delete cascade,
  option   int not null,
  primary key (post_id, user_id)
);

-- Time spent per topic (client batches these every ~30 s)
create table public.topic_time (
  user_id  uuid references public.profiles(id) on delete cascade,
  topic_id int  references public.topics(id) on delete cascade,
  day      date not null default current_date,
  seconds  int  not null default 0,
  primary key (user_id, topic_id, day)
);

create index on public.posts (created_at desc);
create index on public.posts (topic_id, created_at desc);
create index on public.posts (author_id, created_at desc);
create index on public.comments (post_id, created_at);

-- Posts/comments: no contact info anywhere in the feed; round location
create or replace function public.tg_post_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  select * into p from profiles where id = new.author_id;
  if p.status <> 'active' then raise exception 'Account not active'; end if;
  new.lat := round(p.lat::numeric, 2);
  new.lng := round(p.lng::numeric, 2);
  if new.body is not null and cardinality(detect_contact(new.body)) > 0 then
    new.status := 'blocked';
    perform penalize(new.author_id, 'contact_violation', 0.02, null);
    perform notify(new.author_id, 'post_blocked', 'Posts can''t include contact info, links, or social handles.');
  end if;
  return new;
end $$;

create trigger post_before before insert on public.posts
for each row execute function public.tg_post_before();

create or replace function public.tg_comment_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select status from profiles where id = new.author_id) <> 'active' then raise exception 'Account not active'; end if;
  if cardinality(detect_contact(new.body)) > 0 then
    new.status := 'blocked';
    perform penalize(new.author_id, 'contact_violation', 0.02, null);
    perform notify(new.author_id, 'comment_blocked', 'Comments can''t include contact info, links, or social handles.');
  end if;
  return new;
end $$;

create trigger comment_before before insert on public.comments
for each row execute function public.tg_comment_before();

-- AI moderation (service role) marks hostile comments => score hit
create or replace function public.flag_comment_hostile(p_comment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_author uuid;
begin
  update comments set status = 'hostile' where id = p_comment returning author_id into v_author;
  if v_author is not null then perform penalize(v_author, 'hostile_comment', 0.05, null); end if;
end $$;

-- Feed range slider → km
create or replace function public.feed_range_km(p_range text)
returns float8 language sql immutable as $$
  select case p_range
    when 'local'    then 10
    when 'region'   then 50
    when 'province' then 600
    when 'country'  then 5000
    else null end;   -- global
$$;

-- Ranked feed. Like counts are only returned to the post's author.
create or replace function public.get_feed(
  p_range text default null, p_topic int default null,
  p_before timestamptz default null, p_limit int default 30)
returns table (
  post_id uuid, author_id uuid, author_name text, author_photo text,
  topic text, kind text, body text, media_path text, poll_options text[],
  repost_of uuid, created_at timestamptz, distance_km int,
  comment_count int, my_reaction boolean, my_save boolean, like_count int)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v  profiles;
  v_km float8;
begin
  select * into v from profiles where id = me;
  if v.status <> 'active' or effective_tier(me) = 'invisible' then return; end if;
  v_km := feed_range_km(coalesce(p_range, v.feed_range));

  return query
  with base as (
    select po.*,
           case when po.lat is null or v.lat is null then null
                else haversine_km(v.lat, v.lng, po.lat, po.lng) end as km,
           effective_tier(po.author_id) as atier
    from posts po
    join profiles a on a.id = po.author_id and a.status = 'active'
    where po.status = 'visible'
      and (p_before is null or po.created_at < p_before)
      and (p_topic is null or po.topic_id = p_topic)
      and not exists (select 1 from blocks b where (b.blocker = me and b.blocked = po.author_id)
                                               or (b.blocker = po.author_id and b.blocked = me))
      and po.created_at > now() - interval '30 days'
  )
  select b.id, b.author_id, a.display_name,
         (select ph.storage_path from photos ph where ph.user_id = b.author_id and ph.position = 1 and ph.review_status = 'approved'),
         t.name, b.kind, b.body, b.media_path, b.poll_options, b.repost_of, b.created_at,
         case when b.km is null then null else greatest(1, round(b.km))::int end,
         (select count(*)::int from comments c where c.post_id = b.id and c.status = 'visible'),
         exists (select 1 from reactions r where r.post_id = b.id and r.user_id = me),
         exists (select 1 from saves s where s.post_id = b.id and s.user_id = me),
         case when b.author_id = me then (select count(*)::int from reactions r where r.post_id = b.id) else null end
  from base b
  join profiles a on a.id = b.author_id
  join topics t on t.id = b.topic_id
  where b.atier <> 'invisible'
    and (v_km is null or b.km is null or b.km <= v_km)
  order by
    -- relevance score: followed topics, local boost, recency; low-engagement authors sink
    ( case when exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = b.topic_id) then 2.0 else 0 end
    + case when b.km is not null and b.km <= 50 then 1.0 else 0 end
    - extract(epoch from (now() - b.created_at)) / 86400.0
    - case b.atier when 'slipping' then 1.0 when 'low' then 3.0 else 0 end ) desc
  limit least(p_limit, 50);
end $$;

-- ---------------------------------------------------------------------
-- Public profile (photos + interests + recent activity; no bio, no location)
-- ---------------------------------------------------------------------
create or replace function public.get_profile(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
begin
  select * into p from profiles where id = p_user;
  if p.id is null or (p.status <> 'active' and p.id <> me) then return null; end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    return null;
  end if;

  return jsonb_build_object(
    'id', p.id,
    'name', p.display_name,
    'age', extract(year from age(p.birthdate))::int,
    'photos', (select coalesce(jsonb_agg(ph.storage_path order by ph.position), '[]')
                 from photos ph where ph.user_id = p.id and ph.review_status = 'approved'),
    'interests', (select coalesce(jsonb_agg(jsonb_build_object(
                     'name', t.name,
                     'shared', exists (select 1 from user_topics m where m.user_id = me and m.topic_id = t.id))
                   order by t.name), '[]')
                  from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = p.id),
    'recent_activity', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
                  select po.id, po.kind, po.body, t.name as topic, po.created_at
                  from posts po join topics t on t.id = po.topic_id
                  where po.author_id = p.id and po.status = 'visible'
                  order by po.created_at desc limit 10) x)
  );
end $$;

-- My matches with everything the chat screen needs
create or replace function public.get_my_matches()
returns table (
  match_id uuid, other_id uuid, other_name text, other_photo text,
  created_at timestamptz, call_deadline timestamptz, max_deadline timestamptz,
  reschedules_left int, call_done boolean, video_call_done boolean,
  contact_unlocked boolean, icebreaker text, last_message text, last_message_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, o.id, o.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'),
         m.created_at, m.call_deadline, m.max_deadline, 2 - m.reschedules_used,
         m.call_done, m.video_call_done, m.contact_unlocked, m.icebreaker,
         lm.body, lm.created_at
  from matches m
  join profiles o on o.id = case when m.user_a = auth.uid() then m.user_b else m.user_a end
  left join lateral (
    select x.body, x.created_at from messages x
    where x.match_id = m.id and (x.status = 'sent' or x.sender_id = auth.uid())
    order by x.created_at desc limit 1) lm on true
  where auth.uid() in (m.user_a, m.user_b) and m.status = 'active'
  order by coalesce(lm.created_at, m.created_at) desc;
$$;

-- ---------------------------------------------------------------------
-- Safety: reports, blocks, device bans
-- ---------------------------------------------------------------------
create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reported_id uuid not null references public.profiles(id) on delete cascade,
  match_id    uuid references public.matches(id) on delete set null,
  category    text not null check (category in ('fake_profile','harassment','scam','explicit','underage','threats')),
  details     text check (char_length(details) <= 1000),
  priority    boolean not null default false,
  status      text not null default 'open' check (status in ('open','actioned','dismissed')),
  created_at  timestamptz not null default now()
);

create table public.device_hashes (
  user_id     uuid references public.profiles(id) on delete cascade,
  device_hash text not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, device_hash)
);

create table public.banned_devices (
  device_hash text primary key,
  banned_at   timestamptz not null default now()
);

create index on public.reports (reported_id, created_at);
create index on public.reports (status, priority desc, created_at);

create or replace function public.block_user(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  insert into blocks (blocker, blocked) values (me, p_target) on conflict do nothing;
  update matches set status = 'ended', ended_by = me, end_reason = 'deleted', ended_at = now()
  where user_a = least(me, p_target) and user_b = greatest(me, p_target) and status = 'active';
end $$;

-- Report = block + end match + queue for review.
-- 3+ different reporters in 30 days => auto-suspend until a human reviews.
create or replace function public.report_user(p_target uuid, p_category text, p_details text default null, p_match uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_reporters int;
begin
  insert into reports (reporter_id, reported_id, match_id, category, details, priority)
  values (me, p_target, p_match, p_category, p_details, p_category in ('underage','threats'));

  insert into blocks (blocker, blocked) values (me, p_target) on conflict do nothing;
  update matches set status = 'ended', ended_by = me, end_reason = 'report', ended_at = now()
  where user_a = least(me, p_target) and user_b = greatest(me, p_target) and status = 'active';

  select count(distinct reporter_id) into v_reporters
  from reports where reported_id = p_target and created_at > now() - interval '30 days';

  if v_reporters >= 3 or p_category in ('underage','threats') and v_reporters >= 2 then
    update profiles set status = 'suspended', pause_reason = 'Under review' where id = p_target and status = 'active';
  end if;
end $$;

-- Called at sign-in with a device fingerprint; banned devices can't come back
create or replace function public.register_device(p_hash text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from banned_devices where device_hash = p_hash) then
    update profiles set status = 'banned', pause_reason = 'Banned device' where id = auth.uid();
    return false;
  end if;
  insert into device_hashes (user_id, device_hash) values (auth.uid(), p_hash) on conflict do nothing;
  return true;
end $$;

-- Moderator action (service role): permanent ban incl. devices
create or replace function public.ban_user(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set status = 'banned', pause_reason = 'Banned' where id = p_user;
  insert into banned_devices (device_hash)
  select device_hash from device_hashes where user_id = p_user on conflict do nothing;
  update matches set status = 'ended', end_reason = 'report', ended_at = now()
  where p_user in (user_a, user_b) and status = 'active';
end $$;

-- Selfie check result (service role, from photo-check function)
create or replace function public.set_selfie_verified(p_user uuid, p_ok boolean)
returns void language sql security definer set search_path = public as $$
  update profiles set selfie_verified = p_ok where id = p_user;
$$;
