-- Real-world tally (Nov 1 2026, from the Oct 27 vision doc): what Based got you to actually do.
--  * People met in person, friends made, plans that happened, goals finished, milestones ticked off,
--    weeks you hit your number, ideas that became groups. All time, plus the last 30 days.
--  * It rewards doing, not popularity: no likes, followers or views in it, nobody ranked against anyone.
--  * Private by default. You can choose to show it on your profile.
--  * Reads from Who's In (plans that happened) and Goals when those are set up; anything not set up yet counts as 0.
-- Safe to re-run.

alter table public.profiles add column if not exists show_tally boolean not null default false;

-- p_user null = yours. Someone else's only if they chose to show it.
create or replace function public.get_tally(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  u uuid := coalesce(p_user, me);
  v_since timestamptz;
  met_all int := 0; met_30 int := 0;
  friends_all int := 0; friends_30 int := 0;
  plans_all int := 0; plans_30 int := 0;
  goals_all int := 0; goals_30 int := 0;
  steps_all int := 0; steps_30 int := 0;
  weeks_all int := 0; weeks_30 int := 0;
  ideas_all int := 0; ideas_30 int := 0;
  has_plans boolean := to_regclass('public.event_happened') is not null;
  has_goals boolean := to_regclass('public.goals') is not null;
begin
  if u <> me then
    if not coalesce((select show_tally from profiles where id = u and status = 'active'), false)
       or ideas_blocked(me, u) then
      return null;
    end if;
  end if;

  for i in 1..2 loop
    v_since := case when i = 1 then '-infinity'::timestamptz else now() - interval '30 days' end;

    -- people met in person: same-room meets you confirmed, plus everyone at plans you confirmed happened
    execute format($q$
      select count(distinct other) from (
        select case when r.user_a = $1 then r.user_b else r.user_a end as other
        from room_meets r
        where ((r.user_a = $1 and r.a_met) or (r.user_b = $1 and r.b_met))
          and coalesce(r.matched_at, r.created_at) >= $2
        %s
      ) x where other <> $1 $q$,
      case when has_plans then $p$
        union
        select x2.user_id from event_happened h
        join events e on e.id = h.event_id
        join lateral (select rv.user_id from event_rsvps rv where rv.event_id = e.id and rv.status = 'going'
                      union select e.creator_id) x2 on true
        where h.user_id = $1 and h.happened and e.starts_at >= $2 $p$ else '' end)
    into met_30 using u, v_since;
    if i = 1 then met_all := met_30; end if;

    select count(*) into friends_30 from friendships f
    where (f.user_a = u or f.user_b = u) and f.status = 'accepted' and f.created_at >= v_since;
    if i = 1 then friends_all := friends_30; end if;

    if has_plans then
      execute $q$ select count(*) from event_happened h join events e on e.id = h.event_id
                  where h.user_id = $1 and h.happened and e.starts_at >= $2 $q$
      into plans_30 using u, v_since;
      if i = 1 then plans_all := plans_30; end if;
    end if;

    if has_goals then
      execute $q$ select count(*) from goals g join goal_members m on m.goal_id = g.id and m.user_id = $1
                  where g.status = 'done'
                    and coalesce((select max(ms.done_at) from goal_milestones ms where ms.goal_id = g.id), g.created_at) >= $2 $q$
      into goals_30 using u, v_since;
      execute $q$ select count(*) from goal_milestones ms where ms.done_by = $1 and ms.done_at >= $2 $q$
      into steps_30 using u, v_since;
      execute $q$ select count(*) from goal_week_cheers c where c.user_id = $1 and c.week >= ($2::timestamptz)::date $q$
      into weeks_30 using u, case when i = 1 then '1900-01-01'::timestamptz else v_since end;
      if i = 1 then goals_all := goals_30; steps_all := steps_30; weeks_all := weeks_30; end if;
    end if;

    select count(*) into ideas_30 from ideas d
    where d.author_id = u and d.group_id is not null and d.created_at >= v_since;
    if i = 1 then ideas_all := ideas_30; end if;
  end loop;

  return jsonb_build_object(
    'shown', (select show_tally from profiles where id = u),
    'items', jsonb_build_array(
      jsonb_build_object('key','met',     'label','People met in person',     'all', met_all,     'month', met_30),
      jsonb_build_object('key','friends', 'label','Friends made',             'all', friends_all, 'month', friends_30),
      jsonb_build_object('key','plans',   'label','Plans that happened',      'all', plans_all,   'month', plans_30),
      jsonb_build_object('key','goals',   'label','Goals finished',           'all', goals_all,   'month', goals_30),
      jsonb_build_object('key','steps',   'label','Milestones ticked off',    'all', steps_all,   'month', steps_30),
      jsonb_build_object('key','weeks',   'label','Weeks you hit your number','all', weeks_all,   'month', weeks_30),
      jsonb_build_object('key','ideas',   'label','Ideas that became groups', 'all', ideas_all,   'month', ideas_30)));
end $$;

create or replace function public.set_show_tally(p_show boolean)
returns void language sql security definer set search_path = public as $$
  update profiles set show_tally = coalesce(p_show, false) where id = require_tester();
$$;

do $$
declare f text;
begin
  foreach f in array array['public.get_tally(uuid)', 'public.set_show_tally(boolean)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
