-- Pings the owner (admin accounts) whenever someone visits the public website.
-- Every visit is logged; the ping itself is throttled per visitor (30 min cooldown) so repeat
-- page loads from the same person don't flood the owner's phone. Safe to re-run.

create table if not exists public.site_visits (
  id         bigserial primary key,
  visitor    text not null,     -- random id the page generates and stores in localStorage
  page       text,
  referrer   text,
  created_at timestamptz not null default now()
);
create index if not exists site_visits_visitor on public.site_visits (visitor, created_at);
create index if not exists site_visits_created on public.site_visits (created_at);
alter table public.site_visits enable row level security;  -- functions only, no direct client access

-- Called by the public website (anon, no login). Anyone can call this, but it only ever
-- writes a visit row and pings the owner — nothing it returns or touches is sensitive.
create or replace function public.track_site_visit(p_page text, p_visitor text, p_referrer text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_recent boolean;
  v_owner uuid;
begin
  if coalesce(p_visitor, '') = '' then return; end if;

  select exists(
    select 1 from site_visits where visitor = p_visitor and created_at > now() - interval '30 minutes'
  ) into v_recent;

  insert into site_visits (visitor, page, referrer)
  values (p_visitor, left(coalesce(p_page, ''), 200), left(p_referrer, 300));

  if v_recent then return; end if;  -- still logged above; just don't ping again so soon

  for v_owner in select id from profiles where is_admin and status <> 'banned' loop
    perform notify(v_owner, 'site_visit',
      'Someone''s on the site' || case when coalesce(p_page, '') <> '' then ' (' || p_page || ')' else '' end || '.');
  end loop;
end $$;

revoke all on function public.track_site_visit(text, text, text) from public, authenticated;
grant execute on function public.track_site_visit(text, text, text) to anon;

-- Give the push notification a proper title instead of falling back to "Based".
create or replace function public.tg_notification_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform send_push(new.user_id,
    case new.kind
      when 'match'            then 'New match'
      when 'call_proposed'    then 'Call request'
      when 'call_accepted'    then 'Call confirmed'
      when 'call_rescheduled' then 'Call moved'
      when 'call_soon'        then 'Call starting soon'
      when 'no_show'          then 'Missed call'
      when 'call_missed'      then 'Missed call'
      when 'match_expired'    then 'Match expired'
      when 'match_ended'      then 'Match ended'
      when 'contact_unlocked' then 'Numbers unlocked'
      when 'paused'           then 'Account paused'
      when 'unpaused'         then 'You''re visible again'
      when 'waitlist'         then 'Waitlist'
      when 'site_visit'       then 'Site visit'
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;
