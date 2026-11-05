-- Owner alerts and the website analytics page (Nov 3 2026):
--  * Every waitlist signup pings the owner's phone (an in-app notification, which pushes).
--    Once a day passes 10 signups (all cities together), the pings stop for that day and one
--    daily summary goes out that night instead.
--  * The analytics page lives on the website (based-social.com/admin). Only the owner's account can
--    read anything there: every function below checks is_admin, so a stranger who finds the page gets nothing.
--  * "Suggestion" is now its own kind of feedback, sent from its own button next to "Report a problem",
--    and shown on the analytics page alongside bug reports.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Suggestions
-- ---------------------------------------------------------------------
alter table public.app_feedback drop constraint if exists app_feedback_kind_check;
alter table public.app_feedback add constraint app_feedback_kind_check
  check (kind in ('bug', 'confusing', 'idea', 'suggestion'));

-- ---------------------------------------------------------------------
-- Alert log (what was sent, for the analytics page)
-- ---------------------------------------------------------------------
create table if not exists public.admin_alerts (
  id         bigserial primary key,
  kind       text not null check (kind in ('signup','daily_summary')),
  payload    jsonb not null default '{}',
  created_at timestamptz not null default now()
);
alter table public.admin_alerts enable row level security;  -- functions only

create or replace function public.waitlist_day_count(p_day date default null)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from waitlist
  where (created_at at time zone 'America/Edmonton')::date = coalesce(p_day, local_today());
$$;

create or replace function public.tg_waitlist_alert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_today int := waitlist_day_count();
  v_city text := coalesce((select c.name from cities c where c.slug = new.city_slug), new.city, 'somewhere');
  v_owner uuid;
begin
  if v_today > 10 then return null; end if;   -- busy day: the nightly summary covers it
  insert into admin_alerts (kind, payload)
  values ('signup', jsonb_build_object('city', v_city, 'ref', coalesce(new.ref_valid, false), 'today', v_today));
  for v_owner in select id from profiles where is_admin and status <> 'banned' loop
    perform notify(v_owner, 'waitlist',
      'New waitlist signup: ' || v_city
      || case when coalesce(new.ref_valid, false) then ' (with a member''s code)' else '' end
      || '. ' || v_today || ' today.'
      || case when v_today = 10 then ' Any more today go into tonight''s summary.' else '' end);
  end loop;
  return null;
end $$;

drop trigger if exists waitlist_alert on public.waitlist;
create trigger waitlist_alert after insert on public.waitlist
for each row execute function public.tg_waitlist_alert();

-- Tonight's summary, only on days that went past 10
create or replace function public.send_waitlist_summary()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_day date := local_today();
  v_total int := waitlist_day_count(v_day);
  v_top text;
  v_ref int;
  v_owner uuid;
begin
  if v_total <= 10 then return 0; end if;
  if exists (select 1 from admin_alerts where kind = 'daily_summary' and payload ->> 'day' = v_day::text) then return 0; end if;
  select string_agg(x.city || ' ' || x.n, ', ' order by x.n desc) into v_top
  from (select coalesce(c.name, initcap(btrim(w.city)), 'Unknown') as city, count(*) as n
        from waitlist w left join cities c on c.slug = w.city_slug
        where (w.created_at at time zone 'America/Edmonton')::date = v_day
        group by 1 order by 2 desc limit 4) x;
  select count(*) into v_ref from waitlist
  where (created_at at time zone 'America/Edmonton')::date = v_day and ref_valid;

  insert into admin_alerts (kind, payload)
  values ('daily_summary', jsonb_build_object('day', v_day, 'total', v_total, 'with_code', v_ref, 'top', v_top));
  for v_owner in select id from profiles where is_admin and status <> 'banned' loop
    perform notify(v_owner, 'waitlist',
      'Waitlist today: ' || v_total || ' signups (' || v_ref || ' with a member''s code). ' || coalesce(v_top, ''));
  end loop;
  return v_total;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'waitlist-summary') then perform cron.unschedule('waitlist-summary'); end if;
  perform cron.schedule('waitlist-summary', '50 5 * * *', 'select public.send_waitlist_summary()');  -- ~11:50 pm Calgary
end $$;

-- ---------------------------------------------------------------------
-- The analytics page (owner only)
-- ---------------------------------------------------------------------
create or replace function public.admin_waitlist_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := local_today();
begin
  perform require_admin();
  return jsonb_build_object(
    'today', waitlist_day_count(today),
    'mode', case when waitlist_day_count(today) > 10 then 'summary' else 'ping' end,
    'waiting', (select count(*) from waitlist where status = 'waiting'),
    'with_code', (select count(*) from waitlist where status = 'waiting' and ref_valid),
    'days', (select jsonb_agg(jsonb_build_object('day', d::date, 'n', waitlist_day_count(d::date)) order by d)
             from generate_series(today - 13, today, interval '1 day') d),
    'cities_today', (select coalesce(jsonb_agg(jsonb_build_object('city', x.city, 'n', x.n, 'with_code', x.wc) order by x.n desc), '[]')
                     from (select coalesce(c.name, initcap(btrim(w.city)), 'Unknown') as city,
                                  count(*) as n, count(*) filter (where w.ref_valid) as wc
                           from waitlist w left join cities c on c.slug = w.city_slug
                           where (w.created_at at time zone 'America/Edmonton')::date = today
                           group by 1) x),
    'cities_waiting', (select coalesce(jsonb_agg(jsonb_build_object('city', x.city, 'n', x.n, 'open', x.open) order by x.n desc), '[]')
                       from (select coalesce(c.name, initcap(btrim(w.city)), 'Unknown') as city,
                                    count(*) as n, bool_or(c.slug is not null) as open
                             from waitlist w left join cities c on c.slug = w.city_slug
                             where w.status = 'waiting'
                             group by 1 order by 2 desc limit 25) x),
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                  'at', w.created_at, 'city', coalesce(c.name, w.city), 'ref', w.ref_valid, 'email', w.email)
                  order by w.created_at desc), '[]')
               from (select * from waitlist order by created_at desc limit 25) w
               left join cities c on c.slug = w.city_slug),
    'alerts', (select coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'at', a.created_at, 'payload', a.payload)
                  order by a.created_at desc), '[]')
               from (select * from admin_alerts order by created_at desc limit 30) a));
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.admin_waitlist_overview()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.send_waitlist_summary()', 'public.waitlist_day_count(date)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
