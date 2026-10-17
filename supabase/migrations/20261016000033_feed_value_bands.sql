-- =====================================================================
-- Based — feed value bands (top / middle / bottom), "this helped me",
-- creator standing, and value-ranked get_feed.
-- Builds on the existing posts / get_feed setup. Safe to re-run.
-- =====================================================================

-- 1. Value band on every post ------------------------------------------
alter table posts add column if not exists value_band text not null default 'middle'
  check (value_band in ('top', 'middle', 'bottom'));
alter table posts add column if not exists band_source text not null default 'auto'
  check (band_source in ('auto', 'ai', 'admin'));
alter table posts add column if not exists band_reason text;
alter table posts add column if not exists classified_at timestamptz;

-- 2. "This helped me" — the real-response signal ----------------------
create table if not exists post_helps (
  post_id    uuid not null references posts(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table post_helps enable row level security;
drop policy if exists "read own helps" on post_helps;
create policy "read own helps" on post_helps for select using (user_id = auth.uid());
-- writes only through toggle_post_help()

-- 3. Creator standing (hidden, never shown as a number) --------------
alter table user_scores add column if not exists creator_standing real not null default 0;

-- 4. Free v1 classifier (keyword rules). AI classifier can override later
--    by setting band_source = 'ai' with the service role.
create or replace function classify_post_band(p_body text)
returns text language plpgsql immutable as $$
declare
  b text := lower(coalesce(p_body, ''));
  letters int;
  caps int;
begin
  -- bottom: look-at-me / bait
  if b ~ '(smash or pass|rate me|rate my|link in (my )?bio|follow (me|back)|like (this|if)|who else|\mratio\M|thirst|onlyfans|sub to|f4f|l4l)' then
    return 'bottom';
  end if;
  letters := length(regexp_replace(coalesce(p_body, ''), '[^A-Za-z]', '', 'g'));
  caps    := length(regexp_replace(coalesce(p_body, ''), '[^A-Z]', '', 'g'));
  if letters >= 12 and caps::float / letters > 0.7 then
    return 'bottom';
  end if;
  -- top: teaches, opens doors, connects, builds
  if length(b) >= 40 and b ~ '(how to|how i |tip:|tips|lesson|learned|guide|tutorial|step[- ]by[- ]step|explain|here''s why|hiring|\mjobs?\M|position open|opportunit|looking for (a |an )?(co-?founder|partner|mentor|collaborator|developer|designer)|anyone (know|need|want to build)|startup|launch(ed|ing)?|side project|idea for|new tech|\mai\M|resource|workshop|course|introduc(e|ing) you)' then
    return 'top';
  end if;
  return 'middle';
end $$;

create or replace function tg_post_band()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_admin boolean := coalesce((select p.is_admin from profiles p where p.id = auth.uid()), false);
  v_band text;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.band_source := 'auto'; end if;
  else
    -- members can't set their own band
    if auth.uid() is not null and not v_admin then
      new.value_band    := old.value_band;
      new.band_source   := old.band_source;
      new.band_reason   := old.band_reason;
      new.classified_at := old.classified_at;
    end if;
    if new.body is distinct from old.body then
      new.band_source := 'auto';   -- edited text gets re-judged
    else
      return new;
    end if;
  end if;

  if new.band_source = 'auto' then
    if new.repost_of is not null and coalesce(trim(new.body), '') = '' then
      select o.value_band into v_band from posts o where o.id = new.repost_of;
      new.value_band  := coalesce(v_band, 'middle');
      new.band_reason := 'repost';
    else
      new.value_band  := classify_post_band(new.body);
      new.band_reason := 'keywords';
    end if;
    new.classified_at := now();
  end if;
  return new;
end $$;

drop trigger if exists zz_post_band on posts;
create trigger zz_post_band before insert or update on posts
  for each row execute function tg_post_band();

-- backfill existing posts
update posts
   set value_band = classify_post_band(body), band_reason = 'keywords', classified_at = now()
 where classified_at is null;

-- 5. "This helped me" toggle -----------------------------------------
create or replace function toggle_post_help(p_post uuid)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare
  me uuid := auth.uid();
  v_author uuid;
begin
  select po.author_id into v_author from posts po where po.id = p_post and po.status = 'visible';
  if v_author is null then raise exception 'Post not found'; end if;
  if v_author = me then raise exception 'You can''t mark your own post'; end if;
  if exists (select 1 from post_helps h where h.post_id = p_post and h.user_id = me) then
    delete from post_helps h where h.post_id = p_post and h.user_id = me;
    return false;
  end if;
  insert into post_helps (post_id, user_id) values (p_post, me);
  return true;
end $$;
grant execute on function toggle_post_help(uuid) to authenticated;

-- 6. Creator standing recompute (run hourly) -------------------------
create or replace function recompute_creator_standing()
returns integer language sql security definer set search_path to 'public' as $$
  with per_post as (
    select po.author_id,
      case
        when po.value_band = 'bottom' then -0.7
        when po.value_band = 'top' and exists (
          select 1 from post_helps h where h.post_id = po.id and h.user_id <> po.author_id) then 1.0
        when po.value_band = 'top' and po.created_at > now() - interval '48 hours' then 0.3
        when po.value_band = 'top' then 0.1   -- claimed value, nobody confirmed it
        else 0
      end as pts
    from posts po
    where po.status = 'visible' and po.created_at > now() - interval '60 days'
  ),
  agg as (
    select author_id, sum(pts) / greatest(count(*), 3) as s from per_post group by author_id
  ),
  upd as (
    update user_scores us
       set creator_standing = greatest(-1, least(1, coalesce(a.s, 0)))::real
      from profiles p left join agg a on a.author_id = p.id
     where us.user_id = p.id
    returning 1
  )
  select count(*)::int from upd;
$$;
revoke execute on function recompute_creator_standing() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('creator-standing', '20 * * * *', 'select public.recompute_creator_standing()');
  end if;
end $$;

select recompute_creator_standing();

-- 7. Feed ranked by value, not engagement ----------------------------
--    top: +2 boost, decays at half speed (only stays "top" if someone
--         says it helped, or it's under 48h old, or admin set it)
--    middle: normal
--    bottom: -3 and decays 3x faster
--    likes/reactions are NOT in the ranking.
drop function if exists get_feed(text, integer, timestamptz, integer);
create function get_feed(
  p_range  text        default null,
  p_topic  integer     default null,
  p_before timestamptz default null,
  p_limit  integer     default 30)
returns table(
  post_id uuid, author_id uuid, author_name text, author_photo text, topic text,
  kind text, body text, media_path text, poll_options text[], repost_of uuid,
  created_at timestamptz, distance_km integer, comment_count integer,
  my_reaction boolean, my_save boolean, like_count integer, topic_id integer, why text,
  my_help boolean, help_count integer)
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  me uuid := auth.uid();
  v profiles;
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
      effective_tier(po.author_id) as atier,
      coalesce((select f.weight from feed_topic_prefs f where f.user_id = me and f.topic_id = po.topic_id), 0) as tw,
      coalesce((select f.weight from feed_author_prefs f where f.user_id = me and f.author_id = po.author_id), 0) as aw,
      exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = po.topic_id) as follows,
      in_inner_circle(me, po.author_id) as inner_c,
      are_friends(me, po.author_id) as friend,
      (select c.name from circle_members a
         join circle_members b on b.circle_id = a.circle_id
         join circles c on c.id = a.circle_id
        where a.user_id = me and b.user_id = po.author_id limit 1) as circle_name,
      (select count(*) from post_helps h where h.post_id = po.id and h.user_id <> po.author_id)::int as helps,
      coalesce((select us.creator_standing from user_scores us where us.user_id = po.author_id), 0) as standing
    from posts po
    join profiles a on a.id = po.author_id and a.status = 'active'
    where po.status = 'visible'
      and (p_before is null or po.created_at < p_before)
      and (p_topic is null or po.topic_id = p_topic)
      and not exists (select 1 from blocks bl
                       where (bl.blocker = me and bl.blocked = po.author_id)
                          or (bl.blocker = po.author_id and bl.blocked = me))
      and po.created_at > now() - interval '30 days'
  ),
  ranked as (
    select x.*,
      case
        when x.value_band = 'top' and (x.band_source = 'admin' or x.helps > 0
                                       or x.created_at > now() - interval '48 hours') then 'top'
        when x.value_band = 'top' then 'middle'
        else x.value_band
      end as eband
    from base x
  )
  select b.id, b.author_id, a.display_name,
    (select ph.storage_path from photos ph
      where ph.user_id = b.author_id and ph.position = 1 and ph.review_status = 'approved'),
    t.name, b.kind, b.body, b.media_path, b.poll_options, b.repost_of, b.created_at,
    case when b.km is null then null else greatest(1, round(b.km))::int end,
    (select count(*)::int from comments c where c.post_id = b.id and c.status = 'visible'),
    exists (select 1 from reactions r where r.post_id = b.id and r.user_id = me),
    exists (select 1 from saves s where s.post_id = b.id and s.user_id = me),
    case when b.author_id = me then (select count(*)::int from reactions r where r.post_id = b.id) else null end,
    b.topic_id,
    case
      when b.author_id = me then 'Your post'
      when b.inner_c then 'Your inner circle'
      when b.aw > 0 then 'You asked for more from ' || a.display_name
      when b.friend then 'Your friend'
      when b.circle_name is not null then 'In ' || b.circle_name || ' with you'
      when b.tw > 0 then 'You asked for more ' || t.name
      when b.follows then 'You''re into ' || t.name
      when b.km is not null and b.km <= 50 then 'Near you (' || greatest(1, round(b.km))::int || ' km)'
      else 'New in ' || t.name
    end,
    exists (select 1 from post_helps h where h.post_id = b.id and h.user_id = me),
    case when b.author_id = me then b.helps else null end
  from ranked b
  join profiles a on a.id = b.author_id
  join topics t on t.id = b.topic_id
  where b.atier <> 'invisible'
    and b.tw > -2 and b.aw > -2
    and (v_km is null or b.km is null or b.km <= v_km)
  order by (
      case when b.follows then 2.0 else 0 end
    + b.tw * 1.5
    + b.aw * 2.0
    + case when b.inner_c then 2.5 when b.friend then 1.5 when b.circle_name is not null then 1.0 else 0 end
    + case when b.km is not null and b.km <= 50 then 1.0 else 0 end
    -- value band
    + case b.eband when 'top' then 2.0 when 'bottom' then -3.0 else 0 end
    - extract(epoch from (now() - b.created_at)) / 86400.0
        * case b.eband when 'top' then 0.5 when 'bottom' then 3.0 else 1.0 end
    -- quiet reputation + real help
    + greatest(-1, least(1, b.standing)) * 1.5
    + least(b.helps, 10) * 0.15
    - case b.atier when 'slipping' then 1.0 when 'low' then 3.0 else 0 end
  ) desc
  limit least(p_limit, 50);
end $function$;
grant execute on function get_feed(text, integer, timestamptz, integer) to authenticated;

-- 8. Admin tools ------------------------------------------------------
create or replace function admin_set_post_band(p_post uuid, p_band text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not coalesce((select p.is_admin from profiles p where p.id = auth.uid()), false) then
    raise exception 'Not allowed';
  end if;
  if p_band not in ('top', 'middle', 'bottom') then raise exception 'Bad band'; end if;
  update posts set value_band = p_band, band_source = 'admin', band_reason = 'admin', classified_at = now()
   where id = p_post;
end $$;
grant execute on function admin_set_post_band(uuid, text) to authenticated;

create or replace function admin_feed_bands()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not coalesce((select p.is_admin from profiles p where p.id = auth.uid()), false) then
    raise exception 'Not allowed';
  end if;
  return jsonb_build_object(
    'last_7_days', (select coalesce(jsonb_object_agg(value_band, n), '{}') from (
        select po.value_band, count(*) n from posts po
         where po.created_at > now() - interval '7 days' and po.status = 'visible'
         group by po.value_band) s),
    'helps_7_days', (select count(*) from post_helps h where h.created_at > now() - interval '7 days'),
    'recent', (select coalesce(jsonb_agg(r), '[]') from (
        select po.id, left(po.body, 140) as body, po.value_band, po.band_source, po.created_at
          from posts po where po.status = 'visible'
         order by po.created_at desc limit 50) r));
end $$;
grant execute on function admin_feed_bands() to authenticated;
