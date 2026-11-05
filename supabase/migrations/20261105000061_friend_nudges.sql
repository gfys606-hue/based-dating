-- Friend nudges (Nov 3 2026):
--  * Nobody is told they've been away. After 28 days without opening the app, a member's active friends
--    may get a nudge about something they'd both be into: an upcoming event ("you're both into X, see if
--    they want to go") or a recent post ("your friend might like this, share it with them").
--  * The nudge never mentions that the friend hasn't been around.
--  * At most once a week per friend (per pair), and at most one friend nudge a day for anyone.
--  * On by default. Turning it off means you get none, and your friends get none about you.
-- Safe to re-run.

alter table public.profiles add column if not exists friend_nudges boolean not null default true;

create table if not exists public.friend_nudge_log (
  friend_id  uuid not null references public.profiles(id) on delete cascade,   -- who got the nudge
  about_id   uuid not null references public.profiles(id) on delete cascade,   -- the friend it was about
  kind       text not null check (kind in ('event','post')),
  ref_id     uuid,
  created_at timestamptz not null default now()
);
create index if not exists friend_nudge_log_pair on public.friend_nudge_log (friend_id, about_id, created_at desc);
alter table public.friend_nudge_log enable row level security;  -- functions only

-- Last day a member opened the app (null = never recorded)
create or replace function public.last_open_day(p_user uuid)
returns date language sql stable security definer set search_path = public as $$
  select max(day) from activity_days where user_id = p_user;
$$;

create or replace function public.send_friend_nudges()
returns int language plpgsql security definer set search_path = public as $$
declare
  today date := local_today();
  r record;
  e record;
  po record;
  n int := 0;
  v_day text;
begin
  for r in
    select x.id as about_id, x.display_name as about_name, f.id as friend_id
    from profiles x
    join friendships fs on fs.status = 'accepted' and x.id in (fs.user_a, fs.user_b)
    join profiles f on f.id = case when fs.user_a = x.id then fs.user_b else fs.user_a end
    where x.status = 'active' and x.friend_nudges and not is_quiet(x.id)
      and x.created_at < now() - interval '28 days'
      and coalesce(last_open_day(x.id), (x.last_active_at at time zone 'America/Edmonton')::date) <= today - 28
      and f.status = 'active' and f.friend_nudges
      and last_open_day(f.id) >= today - 7
      and not ideas_blocked(x.id, f.id)
      and not exists (select 1 from friend_nudge_log l where l.friend_id = f.id and l.about_id = x.id
                      and l.created_at > now() - interval '7 days')
    order by random()
  loop
    -- one friend nudge a day per person, whoever it's about
    continue when exists (select 1 from friend_nudge_log l where l.friend_id = r.friend_id
                          and l.created_at > now() - interval '20 hours');

    -- 1. an upcoming event both are into that the active friend can see
    select ev.id, ev.title, ev.starts_at, t.name as topic into e
    from events ev
    join topics t on t.id = ev.topic_id
    where ev.status = 'active'
      and ev.starts_at between now() + interval '2 hours' and now() + interval '7 days'
      and ev.creator_id not in (r.about_id, r.friend_id)
      and exists (select 1 from user_topics ut where ut.user_id = r.about_id and ut.topic_id = ev.topic_id)
      and exists (select 1 from user_topics ut where ut.user_id = r.friend_id and ut.topic_id = ev.topic_id)
      and can_see_event(ev.id, r.friend_id)
      and not ideas_blocked(ev.creator_id, r.about_id)
    order by ev.starts_at
    limit 1;

    if e.id is not null then
      v_day := case when night_of(e.starts_at) = night_of(now()) then 'tonight'
                    when night_of(e.starts_at) = night_of(now()) + 1 then 'tomorrow'
                    else 'on ' || to_char(e.starts_at at time zone 'America/Edmonton', 'FMDay') end;
      perform notify(r.friend_id, 'friend_nudge',
        '"' || left(e.title, 60) || '" is ' || v_day || '. You and ' || r.about_name || ' are both into '
        || lower(e.topic) || '. See if they want to go.');
      insert into friend_nudge_log (friend_id, about_id, kind, ref_id) values (r.friend_id, r.about_id, 'event', e.id);
      n := n + 1;
      continue;
    end if;

    -- 2. otherwise a recent post on something they're both into
    select p.id, t.name as topic into po
    from posts p
    join topics t on t.id = p.topic_id
    where p.status = 'visible'
      and p.created_at > now() - interval '7 days'
      and p.author_id not in (r.about_id, r.friend_id)
      and exists (select 1 from user_topics ut where ut.user_id = r.about_id and ut.topic_id = p.topic_id)
      and exists (select 1 from user_topics ut where ut.user_id = r.friend_id and ut.topic_id = p.topic_id)
      and not ideas_blocked(p.author_id, r.friend_id)
      and not ideas_blocked(p.author_id, r.about_id)
    order by p.created_at desc
    limit 1;

    if po.id is not null then
      perform notify(r.friend_id, 'friend_nudge',
        r.about_name || ' might like a new post about ' || lower(po.topic) || '. Share it with them.');
      insert into friend_nudge_log (friend_id, about_id, kind, ref_id) values (r.friend_id, r.about_id, 'post', po.id);
      n := n + 1;
    end if;
  end loop;

  delete from friend_nudge_log where created_at < now() - interval '90 days';
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'friend-nudges') then perform cron.unschedule('friend-nudges'); end if;
  perform cron.schedule('friend-nudges', '37 23 * * *', 'select public.send_friend_nudges()');  -- ~5:30 pm Calgary
end $$;

do $$
begin
  execute 'revoke all on function public.send_friend_nudges() from public, anon, authenticated';
  execute 'revoke all on function public.last_open_day(uuid) from public, anon, authenticated';
end $$;
