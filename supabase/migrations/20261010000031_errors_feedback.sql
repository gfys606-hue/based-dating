-- Tier 1, part 2: error/crash logs tagged with the screen they happened on, and an in-app
-- "Report a problem" button. Both land in the admin Activity screen.

-- Errors: repeats of the same error on the same screen are grouped (count + last seen)
create table if not exists public.app_errors (
  fingerprint text primary key,                  -- screen + first line of the error
  screen      text not null,
  message     text not null,
  stack       text,
  platform    text,
  build       text,
  count       int not null default 1,
  users       uuid[] not null default '{}',      -- who hit it (first 50)
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  resolved    boolean not null default false
);
alter table public.app_errors enable row level security;   -- functions only

create table if not exists public.app_feedback (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete set null,
  kind       text not null check (kind in ('bug', 'confusing', 'idea')),
  screen     text,
  body       text not null check (char_length(body) between 1 and 2000),
  platform   text,
  build      text,
  status     text not null default 'open' check (status in ('open', 'done')),
  created_at timestamptz not null default now()
);
alter table public.app_feedback enable row level security;

-- the app reports an error (anyone, even signed out; grouped so a crash loop can't flood it)
create or replace function public.log_error(p_screen text, p_message text, p_stack text default null,
                                            p_platform text default null, p_build text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  scr text := left(coalesce(nullif(trim(p_screen), ''), 'unknown'), 80);
  msg text := left(coalesce(nullif(trim(p_message), ''), 'unknown error'), 500);
  fp  text := md5(scr || '|' || split_part(msg, E'\n', 1));
begin
  insert into app_errors (fingerprint, screen, message, stack, platform, build, users)
  values (fp, scr, msg, left(p_stack, 4000), left(p_platform, 30), left(p_build, 20),
          case when me is null then '{}'::uuid[] else array[me] end)
  on conflict (fingerprint) do update
     set count = app_errors.count + 1,
         last_seen = now(),
         stack = coalesce(excluded.stack, app_errors.stack),
         platform = coalesce(excluded.platform, app_errors.platform),
         build = coalesce(excluded.build, app_errors.build),
         resolved = case when excluded.build is distinct from app_errors.build then false else app_errors.resolved end,
         users = case when me is null or me = any(app_errors.users) or cardinality(app_errors.users) >= 50
                      then app_errors.users else app_errors.users || me end;
end $$;

create or replace function public.send_feedback(p_kind text, p_body text, p_screen text default null,
                                                p_platform text default null, p_build text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if (select count(*) from app_feedback where user_id = me and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'That''s a lot of reports in an hour. Try again a bit later.';
  end if;
  insert into app_feedback (user_id, kind, screen, body, platform, build)
  values (me, p_kind, left(p_screen, 80), trim(p_body), left(p_platform, 30), left(p_build, 20));
end $$;

-- ---------- admin ----------
create or replace function public.admin_errors(p_include_resolved boolean default false)
returns table (fingerprint text, screen text, message text, stack text, platform text, build text,
               count int, people int, first_seen timestamptz, last_seen timestamptz, resolved boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select e.fingerprint, e.screen, e.message, e.stack, e.platform, e.build, e.count, cardinality(e.users),
         e.first_seen, e.last_seen, e.resolved
  from app_errors e
  where p_include_resolved or not e.resolved
  order by e.resolved, e.last_seen desc
  limit 100;
end $$;

create or replace function public.admin_resolve_error(p_fingerprint text, p_resolved boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update app_errors set resolved = p_resolved where fingerprint = p_fingerprint;
end $$;

create or replace function public.admin_feedback(p_include_done boolean default false)
returns table (id uuid, name text, kind text, screen text, body text, platform text, build text,
               status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select f.id, p.display_name, f.kind, f.screen, f.body, f.platform, f.build, f.status, f.created_at
  from app_feedback f left join profiles p on p.id = f.user_id
  where p_include_done or f.status = 'open'
  order by f.status, f.created_at desc
  limit 200;
end $$;

create or replace function public.admin_set_feedback(p_id uuid, p_done boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  update app_feedback set status = case when p_done then 'done' else 'open' end where id = p_id;
end $$;

-- quick counts for the top of the Activity screen
create or replace function public.admin_health()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return jsonb_build_object(
    'errors_24h', (select coalesce(sum(count), 0) from app_errors where last_seen > now() - interval '24 hours' and not resolved),
    'error_kinds_open', (select count(*) from app_errors where not resolved),
    'people_hit_24h', (select count(distinct u) from app_errors, unnest(users) u where last_seen > now() - interval '24 hours' and not resolved),
    'feedback_open', (select count(*) from app_feedback where status = 'open'),
    'bugs_open', (select count(*) from app_feedback where status = 'open' and kind = 'bug'),
    'confusing_open', (select count(*) from app_feedback where status = 'open' and kind = 'confusing'));
end $$;

do $$
declare f text;
begin
  revoke all on function public.log_error(text,text,text,text,text) from public;
  grant execute on function public.log_error(text,text,text,text,text) to anon, authenticated;
  foreach f in array array[
    'public.send_feedback(text,text,text,text,text)', 'public.admin_errors(boolean)', 'public.admin_resolve_error(text,boolean)',
    'public.admin_feedback(boolean)', 'public.admin_set_feedback(uuid,boolean)', 'public.admin_health()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
