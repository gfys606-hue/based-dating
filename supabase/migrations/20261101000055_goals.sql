-- Goals and challenges (Nov 1 2026, from the Oct 27 vision doc): groups with a purpose, positive accountability.
--  * A goal belongs to a Herd (members opt in with "I'm in") or to just you.
--  * Two kinds: a habit (e.g. work out 3 times a week for 12 weeks) or milestones
--    (e.g. 90-day launch: idea, research, plan, first customer, website, first $1,000, launch).
--  * Challenges are ready-made goals anyone can start, alone or with their Herd.
--  * Positive accountability only, never shaming:
--      - hitting your weekly number tells the others in the goal ("Sam hit 3 this week on Morning lifts")
--      - a finished milestone tells everyone in the goal
--      - Saturday morning, a Herd goal nobody has checked into this week gets one friendly nudge to the group
--        ("Nobody's been out yet this week. Saturday looks good."), never naming anyone
--  * The people in a goal see each other's progress on it. Nobody else does.
--  * Goals end on their end date (or when every milestone is done).
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.challenges (
  slug       text primary key,
  title      text not null,
  blurb      text not null,
  kind       text not null check (kind in ('habit','milestones')),
  per_week   int check (per_week between 1 and 14),
  days       int not null check (days between 7 and 366),
  milestones jsonb not null default '[]'::jsonb,   -- ["Idea", "Research", ...]
  sort       int not null default 0,
  active     boolean not null default true
);

create table if not exists public.goals (
  id             uuid primary key default gen_random_uuid(),
  circle_id      uuid references public.circles(id) on delete cascade,   -- null = personal
  created_by     uuid not null references public.profiles(id) on delete cascade,
  title          text not null check (char_length(title) between 3 and 80),
  kind           text not null check (kind in ('habit','milestones')),
  per_week       int check (per_week between 1 and 14),
  starts_on      date not null,
  ends_on        date not null,
  challenge_slug text references public.challenges(slug) on delete set null,
  status         text not null default 'active' check (status in ('active','done','ended')),
  created_at     timestamptz not null default now(),
  check (kind <> 'habit' or per_week is not null),
  check (ends_on > starts_on)
);
create index if not exists goals_circle on public.goals (circle_id, status);

create table if not exists public.goal_members (
  goal_id   uuid not null references public.goals(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (goal_id, user_id)
);
create index if not exists goal_members_user on public.goal_members (user_id);

create table if not exists public.goal_checkins (
  goal_id uuid not null references public.goals(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  day     date not null,
  primary key (goal_id, user_id, day)
);

create table if not exists public.goal_milestones (
  id       uuid primary key default gen_random_uuid(),
  goal_id  uuid not null references public.goals(id) on delete cascade,
  position int not null,
  title    text not null check (char_length(title) between 1 and 80),
  done_at  timestamptz,
  done_by  uuid references public.profiles(id) on delete set null
);
create index if not exists goal_milestones_goal on public.goal_milestones (goal_id, position);

-- so "hit your number this week" is announced once per person per week
create table if not exists public.goal_week_cheers (
  goal_id uuid not null references public.goals(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  week    date not null,
  primary key (goal_id, user_id, week)
);

alter table public.challenges       enable row level security;
alter table public.goals            enable row level security;
alter table public.goal_members     enable row level security;
alter table public.goal_checkins    enable row level security;
alter table public.goal_milestones  enable row level security;
alter table public.goal_week_cheers enable row level security;

-- ---------------------------------------------------------------------
-- Ready-made challenges
-- ---------------------------------------------------------------------
insert into public.challenges (slug, title, blurb, kind, per_week, days, milestones, sort) values
 ('90-day-launch', '90-Day Business Launch',
  'Go from idea to first sale in 90 days. Tick off each step as you go; your herd sees every win.',
  'milestones', null, 90,
  '["Pick the idea","Talk to 10 potential customers","Write a one-page plan","Land your first customer","Get a website up","Make your first $1,000","Launch"]', 10),
 ('12-week-fitness', '12-Week Training Block',
  'Three workouts a week for 12 weeks. Check in after each one.',
  'habit', 3, 84, '[]', 20),
 ('summer-outdoors-2027', 'Summer 2027 Outdoors',
  'Get outside before the leaves turn: a camping trip, a fishing day, a summit and a night under the stars.',
  'milestones', null, 180,
  '["Plan the first trip","Go camping","Go fishing","Hike to a summit","Sleep under the stars","Bring someone new along"]', 30),
 ('meet-people-30', '30 Days of New People',
  'Meet one new person in real life each week for a month: an event, a plan, a check-in meet.',
  'habit', 1, 30, '[]', 40),
 ('read-12', 'A Book a Month',
  'Twelve books in a year, with a herd to talk them through. Tick one off when you finish it.',
  'milestones', null, 365,
  '["Book 1","Book 2","Book 3","Book 4","Book 5","Book 6","Book 7","Book 8","Book 9","Book 10","Book 11","Book 12"]', 50),
 ('build-in-public', 'Build in Public, 8 Weeks',
  'Post one update a week on what you''re building, in Ideas or your herd. Momentum beats perfection.',
  'habit', 1, 56, '[]', 60)
on conflict (slug) do update
  set title = excluded.title, blurb = excluded.blurb, kind = excluded.kind, per_week = excluded.per_week,
      days = excluded.days, milestones = excluded.milestones, sort = excluded.sort;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.goal_week_start(p_day date)
returns date language sql immutable as $$
  select date_trunc('week', p_day)::date;   -- Monday
$$;

-- can this person see / act on this goal?
create or replace function public.goal_visible(p_goal public.goals, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case when p_goal.circle_id is null
              then exists (select 1 from goal_members m where m.goal_id = p_goal.id and m.user_id = p_user)
              else exists (select 1 from circle_members c where c.circle_id = p_goal.circle_id and c.user_id = p_user)
         end;
$$;

-- tell everyone else in the goal
create or replace function public.goal_tell_others(p_goal uuid, p_except uuid, p_body text)
returns void language sql security definer set search_path = public as $$
  select notify(m.user_id, 'goal', p_body)
  from goal_members m
  join profiles p on p.id = m.user_id and p.status = 'active'
  where m.goal_id = p_goal and m.user_id <> p_except;
$$;

-- ---------------------------------------------------------------------
-- Creating goals
-- ---------------------------------------------------------------------
create or replace function public.create_goal(p_circle uuid, p_title text, p_kind text, p_per_week int,
                                              p_ends_on date, p_milestones jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_id uuid;
  v_title text := btrim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g'));
  m text;
  i int := 0;
begin
  if (select status from profiles where id = me) is distinct from 'active' then
    raise exception 'Finish setting up your profile first.';
  end if;
  if p_circle is not null and not exists (select 1 from circle_members where circle_id = p_circle and user_id = me) then
    raise exception 'You''re not in that herd.';
  end if;
  if char_length(v_title) < 3 then raise exception 'Give the goal a name.'; end if;
  if blocked_term_in(v_title) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
  if cardinality(detect_contact(v_title)) > 0 then raise exception 'Goal names can''t include contact info or links.'; end if;
  if p_kind not in ('habit','milestones') then raise exception 'Pick a habit or milestones.'; end if;
  if p_kind = 'habit' and (p_per_week is null or p_per_week not between 1 and 14) then
    raise exception 'How many times a week? Pick 1 to 14.';
  end if;
  if p_ends_on is null or p_ends_on <= local_today() or p_ends_on > local_today() + 366 then
    raise exception 'Pick an end date within the next year.';
  end if;
  if p_kind = 'milestones' and jsonb_array_length(coalesce(p_milestones, '[]'::jsonb)) not between 1 and 20 then
    raise exception 'Add 1 to 20 milestones.';
  end if;
  if (select count(*) from goals g where g.status = 'active'
        and (case when p_circle is null then g.circle_id is null and g.created_by = me
                  else g.circle_id = p_circle end)) >= 5 then
    raise exception 'That''s 5 active goals already. Finish or end one first.';
  end if;

  insert into goals (circle_id, created_by, title, kind, per_week, starts_on, ends_on)
  values (p_circle, me, left(v_title, 80), p_kind, case when p_kind = 'habit' then p_per_week end, local_today(), p_ends_on)
  returning id into v_id;
  insert into goal_members (goal_id, user_id) values (v_id, me);

  if p_kind = 'milestones' then
    for m in select jsonb_array_elements_text(p_milestones) loop
      m := left(btrim(m), 80);
      continue when char_length(m) = 0;
      if blocked_term_in(m) is not null or cardinality(detect_contact(m)) > 0 then
        raise exception 'One of the milestones has wording that isn''t allowed.';
      end if;
      i := i + 1;
      insert into goal_milestones (goal_id, position, title) values (v_id, i, m);
    end loop;
    if i = 0 then raise exception 'Add at least one milestone.'; end if;
  end if;

  if p_circle is not null then
    perform notify(c.user_id, 'goal',
      (select display_name from profiles where id = me) || ' started a goal in your herd: "' || left(v_title, 60) || '". Tap I''m in if you''re in.')
    from circle_members c where c.circle_id = p_circle and c.user_id <> me;
  end if;
  return v_id;
end $$;

create or replace function public.start_challenge(p_slug text, p_circle uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  c challenges;
  v_id uuid;
begin
  select * into c from challenges where slug = p_slug and active;
  if c.slug is null then raise exception 'That challenge isn''t available.'; end if;
  v_id := create_goal(p_circle, c.title, c.kind, c.per_week, local_today() + c.days, c.milestones);
  update goals set challenge_slug = c.slug where id = v_id;
  return v_id;
end $$;

create or replace function public.get_challenges()
returns table (slug text, title text, blurb text, kind text, per_week int, days int, milestones jsonb)
language sql stable security definer set search_path = public as $$
  select c.slug, c.title, c.blurb, c.kind, c.per_week, c.days, c.milestones
  from challenges c where c.active and require_tester() is not null order by c.sort;
$$;

-- ---------------------------------------------------------------------
-- Joining, checking in, milestones
-- ---------------------------------------------------------------------
create or replace function public.join_goal(p_goal uuid, p_join boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  g goals;
begin
  select * into g from goals where id = p_goal;
  if g.id is null or not goal_visible(g, me) then raise exception 'That goal is gone.'; end if;
  if p_join then
    if g.status <> 'active' then raise exception 'That goal has ended.'; end if;
    if g.circle_id is null then raise exception 'That goal is personal.'; end if;
    insert into goal_members (goal_id, user_id) values (g.id, me) on conflict do nothing;
  else
    delete from goal_members where goal_id = g.id and user_id = me;
    -- a personal goal nobody is in any more is simply ended
    if g.circle_id is null then update goals set status = 'ended' where id = g.id; end if;
  end if;
end $$;

-- Habit check-in for today (or undo it). Hitting your weekly number tells the others, once a week.
create or replace function public.goal_check_in(p_goal uuid, p_done boolean default true)
returns int language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  g goals;
  v_today date := local_today();
  v_week date := goal_week_start(local_today());
  v_count int;
begin
  select * into g from goals where id = p_goal;
  if g.id is null or g.kind <> 'habit' then raise exception 'That goal is gone.'; end if;
  if g.status <> 'active' then raise exception 'That goal has ended.'; end if;
  if not exists (select 1 from goal_members where goal_id = g.id and user_id = me) then
    raise exception 'Tap I''m in first.';
  end if;

  if p_done then
    insert into goal_checkins (goal_id, user_id, day) values (g.id, me, v_today) on conflict do nothing;
  else
    delete from goal_checkins where goal_id = g.id and user_id = me and day = v_today;
  end if;

  select count(*) into v_count from goal_checkins
  where goal_id = g.id and user_id = me and day >= v_week and day < v_week + 7;

  if p_done and v_count >= g.per_week
     and not exists (select 1 from goal_week_cheers where goal_id = g.id and user_id = me and week = v_week) then
    insert into goal_week_cheers (goal_id, user_id, week) values (g.id, me, v_week);
    perform goal_tell_others(g.id, me,
      (select display_name from profiles where id = me) || ' hit ' || g.per_week || ' this week on "' || left(g.title, 50) || '".');
  end if;
  return v_count;
end $$;

create or replace function public.set_goal_milestone(p_milestone uuid, p_done boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  m goal_milestones;
  g goals;
  v_name text;
begin
  select * into m from goal_milestones where id = p_milestone;
  select * into g from goals where id = m.goal_id;
  if g.id is null then raise exception 'That goal is gone.'; end if;
  if not exists (select 1 from goal_members where goal_id = g.id and user_id = me) then
    raise exception 'Tap I''m in first.';
  end if;
  if g.status = 'ended' then raise exception 'That goal has ended.'; end if;

  if p_done then
    if m.done_at is not null then return; end if;
    update goal_milestones set done_at = now(), done_by = me where id = m.id;
    select display_name into v_name from profiles where id = me;
    if not exists (select 1 from goal_milestones where goal_id = g.id and done_at is null) then
      update goals set status = 'done' where id = g.id;
      perform goal_tell_others(g.id, me, 'Done! "' || left(g.title, 50) || '" is complete. ' || v_name || ' ticked off the last step.');
    else
      perform goal_tell_others(g.id, me, v_name || ' ticked off "' || left(m.title, 50) || '" on "' || left(g.title, 40) || '".');
    end if;
  else
    update goal_milestones set done_at = null, done_by = null where id = m.id;
    update goals set status = 'active' where id = g.id and status = 'done' and ends_on > local_today();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Reading goals
-- ---------------------------------------------------------------------
-- p_circle null = every goal you're in (yours and your herds'); otherwise the herd's goals.
create or replace function public.get_goals(p_circle uuid default null)
returns table (goal_id uuid, circle_id uuid, circle_name text, title text, kind text, per_week int,
               starts_on date, ends_on date, days_left int, status text, challenge_slug text,
               joined boolean, mine boolean, my_week int, checked_today boolean, members jsonb, milestones jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_week date := goal_week_start(local_today());
begin
  if p_circle is not null and not exists (select 1 from circle_members cm where cm.circle_id = p_circle and cm.user_id = me) then
    raise exception 'You''re not in that herd.';
  end if;
  return query
  select g.id, g.circle_id, c.name, g.title, g.kind, g.per_week, g.starts_on, g.ends_on,
         greatest(0, g.ends_on - local_today()), g.status, g.challenge_slug,
         exists (select 1 from goal_members m where m.goal_id = g.id and m.user_id = me),
         g.created_by = me,
         (select count(*)::int from goal_checkins k where k.goal_id = g.id and k.user_id = me
            and k.day >= v_week and k.day < v_week + 7),
         exists (select 1 from goal_checkins k where k.goal_id = g.id and k.user_id = me and k.day = local_today()),
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'user_id', m.user_id, 'name', p.display_name,
                   'photo', (select ph.storage_path from photos ph where ph.user_id = m.user_id and ph.position = 1 and ph.review_status = 'approved'),
                   'week', (select count(*) from goal_checkins k where k.goal_id = g.id and k.user_id = m.user_id
                              and k.day >= v_week and k.day < v_week + 7))
                 order by m.joined_at), '[]'::jsonb)
            from goal_members m join profiles p on p.id = m.user_id and p.status = 'active'
           where m.goal_id = g.id),
         (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', ms.id, 'title', ms.title, 'done', ms.done_at is not null,
                   'done_by', (select display_name from profiles where id = ms.done_by))
                 order by ms.position), '[]'::jsonb)
            from goal_milestones ms where ms.goal_id = g.id)
  from goals g
  left join circles c on c.id = g.circle_id
  where (case when p_circle is null
              then exists (select 1 from goal_members m where m.goal_id = g.id and m.user_id = me)
              else g.circle_id = p_circle end)
    and (g.status in ('active','done') or g.ends_on > local_today() - 30)
  order by (g.status = 'active') desc, g.ends_on, g.created_at;
end $$;

-- ---------------------------------------------------------------------
-- Daily upkeep and the Saturday nudge
-- ---------------------------------------------------------------------
create or replace function public.sweep_goals()
returns void language sql security definer set search_path = public as $$
  update goals set status = 'ended' where status = 'active' and ends_on < local_today();
$$;

-- A herd habit goal nobody has checked into this week gets one friendly group nudge. Never names anyone.
create or replace function public.saturday_goal_nudge()
returns int language plpgsql security definer set search_path = public as $$
declare
  g record;
  n int := 0;
  v_week date := goal_week_start(local_today());
begin
  for g in
    select x.* from goals x
    where x.status = 'active' and x.kind = 'habit' and x.circle_id is not null
      and (select count(*) from goal_members m where m.goal_id = x.id) >= 2
      and not exists (select 1 from goal_checkins k where k.goal_id = x.id and k.day >= v_week)
  loop
    perform notify(m.user_id, 'goal',
      'Nobody''s checked in on "' || left(g.title, 50) || '" yet this week. Saturday looks like a good day for it.')
    from goal_members m join profiles p on p.id = m.user_id and p.status = 'active'
    where m.goal_id = g.id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'sweep-goals') then perform cron.unschedule('sweep-goals'); end if;
  if exists (select 1 from cron.job where jobname = 'saturday-goal-nudge') then perform cron.unschedule('saturday-goal-nudge'); end if;
  perform cron.schedule('sweep-goals', '7 8 * * *', 'select public.sweep_goals()');                 -- ~1 am Calgary
  perform cron.schedule('saturday-goal-nudge', '17 16 * * 6', 'select public.saturday_goal_nudge()'); -- Saturday ~9 am Calgary
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_goal(uuid,text,text,int,date,jsonb)', 'public.start_challenge(text,uuid)',
    'public.get_challenges()', 'public.join_goal(uuid,boolean)', 'public.goal_check_in(uuid,boolean)',
    'public.set_goal_milestone(uuid,boolean)', 'public.get_goals(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.goal_visible(public.goals,uuid)', 'public.goal_tell_others(uuid,uuid,text)',
    'public.sweep_goals()', 'public.saturday_goal_nudge()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
