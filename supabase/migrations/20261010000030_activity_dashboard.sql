-- Activity dashboard (admin): are people using it, are they connecting, do the flows work.
-- Tier 1: pulse (members, daily/weekly/monthly active), a 14-day chart, the signup funnel,
-- connecting this week vs last week, and stuck points.
-- Days are counted in Calgary time.

-- one row per member per day they opened the app
create table if not exists public.activity_days (
  user_id uuid references public.profiles(id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);
alter table public.activity_days enable row level security;   -- functions only
create index if not exists activity_days_day on public.activity_days (day);

create or replace function public.local_today()
returns date language sql stable as $$
  select (now() at time zone 'America/Edmonton')::date;
$$;

-- the app calls this when it opens or comes back to the foreground
create or replace function public.touch_active()
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null or not exists (select 1 from profiles where id = me) then return; end if;
  insert into activity_days (user_id, day) values (me, local_today()) on conflict do nothing;
  update profiles set last_active_at = now() where id = me and last_active_at < now() - interval '5 minutes';
end $$;

-- backfill what we can: anyone active recently counts for the day they were last seen
insert into public.activity_days (user_id, day)
select id, (last_active_at at time zone 'America/Edmonton')::date from public.profiles
where last_active_at > now() - interval '30 days'
on conflict do nothing;

create or replace function public.admin_activity()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  today date := local_today();
  w0 timestamptz := now() - interval '7 days';    -- this week
  w1 timestamptz := now() - interval '14 days';   -- last week
  r jsonb;
begin
  perform require_admin();

  with
  members as (select * from profiles where status <> 'banned'),
  daily as (
    select d::date as day,
           (select count(*) from profiles p where (p.created_at at time zone 'America/Edmonton')::date = d::date) as joined,
           (select count(*) from activity_days a where a.day = d::date) as active
    from generate_series(today - 13, today, interval '1 day') d
  ),
  -- people who joined in the last 30 days, and how far each got
  cohort as (
    select p.id, p.status,
      exists (select 1 from invite_redemptions r where r.user_id = p.id) as redeemed,
      (select count(*) from photos ph where ph.user_id = p.id) >= 3 as photos3,
      exists (select 1 from friendships f where f.status = 'accepted' and p.id in (f.user_a, f.user_b))
        or exists (select 1 from matches m where p.id in (m.user_a, m.user_b))
        or exists (select 1 from circle_members cm where cm.user_id = p.id) as connected,
      exists (select 1 from messages x where x.sender_id = p.id)
        or exists (select 1 from friend_messages x where x.sender_id = p.id)
        or exists (select 1 from circle_messages x where x.sender_id = p.id) as messaged,
      exists (select 1 from activity_days a where a.user_id = p.id and a.day >= (p.created_at at time zone 'America/Edmonton')::date + 1) as came_back
    from profiles p where p.created_at > now() - interval '30 days'
  )
  select jsonb_build_object(
    'today', today,
    'pulse', jsonb_build_object(
      'members', (select count(*) from members where status = 'active'),
      'onboarding', (select count(*) from members where status = 'onboarding'),
      'paused', (select count(*) from members where status in ('paused', 'suspended')),
      'new_today', (select count(*) from profiles where (created_at at time zone 'America/Edmonton')::date = today),
      'new_7d', (select count(*) from profiles where created_at > w0),
      'new_prev_7d', (select count(*) from profiles where created_at > w1 and created_at <= w0),
      'dau', (select count(*) from activity_days where day = today),
      'wau', (select count(distinct user_id) from activity_days where day > today - 7),
      'mau', (select count(distinct user_id) from activity_days where day > today - 30),
      'waitlist', (select count(*) from waitlist where coalesce(status, 'waiting') = 'waiting'),
      'tracking_since', (select min(day) from activity_days)),
    'daily', (select jsonb_agg(jsonb_build_object('day', day, 'joined', joined, 'active', active) order by day) from daily),
    'funnel', jsonb_build_object(
      'signed_up', (select count(*) from cohort),
      'used_code', (select count(*) from cohort where redeemed),
      'profile_done', (select count(*) from cohort where status in ('active', 'paused') and photos3),
      'connected', (select count(*) from cohort where connected),
      'messaged', (select count(*) from cohort where messaged),
      'came_back', (select count(*) from cohort where came_back)),
    'connecting', (select jsonb_agg(jsonb_build_object('key', k, 'label', l, 'now', n, 'before', b) order by o) from (values
      (1, 'friend_req', 'Friend requests sent',
        (select count(*) from friendships where created_at > w0),
        (select count(*) from friendships where created_at > w1 and created_at <= w0)),
      (2, 'friends', 'Friendships made',
        (select count(*) from friendships where status = 'accepted' and responded_at > w0),
        (select count(*) from friendships where status = 'accepted' and responded_at > w1 and responded_at <= w0)),
      (3, 'herd_joins', 'Joined a herd',
        (select count(*) from circle_nominations where status = 'joined' and decided_at > w0),
        (select count(*) from circle_nominations where status = 'joined' and decided_at > w1 and decided_at <= w0)),
      (4, 'plans', 'Plans posted',
        (select count(*) from events where created_at > w0),
        (select count(*) from events where created_at > w1 and created_at <= w0)),
      (5, 'rsvps', 'RSVPs',
        (select count(*) from event_rsvps where created_at > w0),
        (select count(*) from event_rsvps where created_at > w1 and created_at <= w0)),
      (6, 'checkins', '"I''m here now" check-ins',
        (select count(*) from checkins where started_at > w0),
        (select count(*) from checkins where started_at > w1 and started_at <= w0)),
      (7, 'likes', 'Ouch likes',
        (select count(*) from likes where created_at > w0),
        (select count(*) from likes where created_at > w1 and created_at <= w0)),
      (8, 'matches', 'Ouch matches',
        (select count(*) from matches where created_at > w0),
        (select count(*) from matches where created_at > w1 and created_at <= w0)),
      (9, 'calls', 'Calls completed (5+ min)',
        (select count(*) from calls where status = 'completed' and ended_at > w0),
        (select count(*) from calls where status = 'completed' and ended_at > w1 and ended_at <= w0)),
      (10, 'messages', 'Messages sent',
        (select count(*) from messages where created_at > w0)
          + (select count(*) from friend_messages where created_at > w0)
          + (select count(*) from circle_messages where created_at > w0),
        (select count(*) from messages where created_at > w1 and created_at <= w0)
          + (select count(*) from friend_messages where created_at > w1 and created_at <= w0)
          + (select count(*) from circle_messages where created_at > w1 and created_at <= w0)),
      (11, 'posts', 'Posts',
        (select count(*) from posts where created_at > w0),
        (select count(*) from posts where created_at > w1 and created_at <= w0))
    ) v(o, k, l, n, b)),
    'stuck', jsonb_build_object(
      'matches_expired_7d', (select count(*) from matches where end_reason in ('expired', 'no_show', 'reschedules_exhausted') and ended_at > w0),
      'matches_7d', (select count(*) from matches where created_at > w0),
      'requests_waiting_3d', (select count(*) from friendships where status = 'pending' and created_at < now() - interval '3 days'),
      'stuck_onboarding', (select count(*) from profiles where status = 'onboarding' and created_at < now() - interval '2 days'),
      'photos_paused', (select count(*) from profiles where status = 'paused'),
      'reports_open', (select count(*) from reports where status = 'open'),
      'codes_never_used', (select count(*) from invite_codes where uses = 0 and created_at < now() - interval '7 days' and active))
  ) into r;
  return r;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.touch_active()', 'public.admin_activity()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
