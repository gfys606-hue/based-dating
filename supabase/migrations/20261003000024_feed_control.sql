-- Your feed, your rules.
--  * Steer it: more / less / hide for any topic, and "less from this person" or hide them.
--  * See why: every post says why it's there ("Your inner circle", "You asked for more Whisky", "Near you").
--  * Reset it: one tap clears everything you've told it.
-- (The hidden engagement score still quietly sinks people who collect matches; it is never shown as a reason.)

create table if not exists public.feed_topic_prefs (
  user_id    uuid references public.profiles(id) on delete cascade,
  topic_id   int references public.topics(id) on delete cascade,
  weight     int not null check (weight between -2 and 2),  -- -2 = hide, -1 = less, 1 = more, 2 = lots more
  updated_at timestamptz not null default now(),
  primary key (user_id, topic_id)
);

create table if not exists public.feed_author_prefs (
  user_id    uuid references public.profiles(id) on delete cascade,
  author_id  uuid references public.profiles(id) on delete cascade,
  weight     int not null check (weight between -2 and 1),  -- -2 = hide, -1 = less, 1 = more
  updated_at timestamptz not null default now(),
  primary key (user_id, author_id)
);

alter table public.feed_topic_prefs  enable row level security;  -- functions only
alter table public.feed_author_prefs enable row level security;

create or replace function public.set_topic_pref(p_topic int, p_weight int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_weight, 0) = 0 then
    delete from feed_topic_prefs where user_id = auth.uid() and topic_id = p_topic;
  else
    insert into feed_topic_prefs (user_id, topic_id, weight) values (auth.uid(), p_topic, greatest(-2, least(2, p_weight)))
    on conflict (user_id, topic_id) do update set weight = excluded.weight, updated_at = now();
  end if;
end $$;

create or replace function public.set_author_pref(p_author uuid, p_weight int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_author = auth.uid() then return; end if;
  if coalesce(p_weight, 0) = 0 then
    delete from feed_author_prefs where user_id = auth.uid() and author_id = p_author;
  else
    insert into feed_author_prefs (user_id, author_id, weight) values (auth.uid(), p_author, greatest(-2, least(1, p_weight)))
    on conflict (user_id, author_id) do update set weight = excluded.weight, updated_at = now();
  end if;
end $$;

create or replace function public.get_feed_prefs()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'topics', (select coalesce(jsonb_agg(jsonb_build_object('topic_id', t.id, 'name', t.name, 'weight', f.weight) order by f.weight desc, t.name), '[]')
               from feed_topic_prefs f join topics t on t.id = f.topic_id where f.user_id = auth.uid()),
    'people', (select coalesce(jsonb_agg(jsonb_build_object('user_id', p.id, 'name', p.display_name, 'weight', f.weight) order by f.weight desc, p.display_name), '[]')
               from feed_author_prefs f join profiles p on p.id = f.author_id where f.user_id = auth.uid()));
$$;

-- Start over: forget every steer (follows from your interests stay)
create or replace function public.reset_feed()
returns void language sql security definer set search_path = public as $$
  delete from feed_topic_prefs where user_id = auth.uid();
  delete from feed_author_prefs where user_id = auth.uid();
$$;

drop function if exists public.get_feed(text, int, timestamptz, int);
create or replace function public.get_feed(
  p_range text default null, p_topic int default null,
  p_before timestamptz default null, p_limit int default 30)
returns table (
  post_id uuid, author_id uuid, author_name text, author_photo text,
  topic text, kind text, body text, media_path text, poll_options text[],
  repost_of uuid, created_at timestamptz, distance_km int,
  comment_count int, my_reaction boolean, my_save boolean, like_count int,
  topic_id int, why text)
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
           effective_tier(po.author_id) as atier,
           coalesce((select f.weight from feed_topic_prefs f where f.user_id = me and f.topic_id = po.topic_id), 0) as tw,
           coalesce((select f.weight from feed_author_prefs f where f.user_id = me and f.author_id = po.author_id), 0) as aw,
           exists (select 1 from user_topics ut where ut.user_id = me and ut.topic_id = po.topic_id) as follows,
           in_inner_circle(me, po.author_id) as inner_c,
           are_friends(me, po.author_id) as friend,
           (select c.name from circle_members a join circle_members b on b.circle_id = a.circle_id join circles c on c.id = a.circle_id
             where a.user_id = me and b.user_id = po.author_id limit 1) as circle_name
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
           else 'New in ' || t.name end
  from base b
  join profiles a on a.id = b.author_id
  join topics t on t.id = b.topic_id
  where b.atier <> 'invisible'
    and b.tw > -2 and b.aw > -2                         -- hidden topics and people never show
    and (v_km is null or b.km is null or b.km <= v_km)
  order by
    ( case when b.follows then 2.0 else 0 end
    + b.tw * 1.5
    + b.aw * 2.0
    + case when b.inner_c then 2.5 when b.friend then 1.5 when b.circle_name is not null then 1.0 else 0 end
    + case when b.km is not null and b.km <= 50 then 1.0 else 0 end
    - extract(epoch from (now() - b.created_at)) / 86400.0
    - case b.atier when 'slipping' then 1.0 when 'low' then 3.0 else 0 end ) desc
  limit least(p_limit, 50);
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.set_topic_pref(int,int)', 'public.set_author_pref(uuid,int)', 'public.get_feed_prefs()', 'public.reset_feed()',
    'public.get_feed(text,int,timestamptz,int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
