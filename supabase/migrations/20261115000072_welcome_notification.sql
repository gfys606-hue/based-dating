-- Send every new user a welcome notice (shows up under "Heads up" in-app),
-- introducing the beta and encouraging them to try features and add friends.

create or replace function public.tg_profile_created()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into user_scores (user_id) values (new.id) on conflict do nothing;

  perform notify(
    new.id,
    'welcome',
    'Welcome to Based Social! We''re still in beta, so dig into every feature and let us know if anything feels off. Add as many friends as you can -- the more people you connect with, the better this works for everyone.'
  );

  return new;
end
$$;

-- Give the welcome notice its own push title (in case push is ever enabled for it).
create or replace function public.tg_notification_push()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform send_push(new.user_id, case new.kind
    when 'match' then 'New match'
    when 'call_proposed' then 'Call request'
    when 'call_accepted' then 'Call confirmed'
    when 'call_rescheduled' then 'Call moved'
    when 'call_soon' then 'Call starting soon'
    when 'no_show' then 'Missed call'
    when 'call_missed' then 'Missed call'
    when 'match_expired' then 'Match expired'
    when 'match_ended' then 'Match ended'
    when 'contact_unlocked' then 'Numbers unlocked'
    when 'paused' then 'Account paused'
    when 'unpaused' then 'You''re visible again'
    when 'waitlist' then 'Waitlist'
    when 'site_visit' then 'Site visit'
    when 'welcome' then 'Welcome to Based'
    else 'Based'
  end, new.body, jsonb_build_object('kind', new.kind));
  return null;
end
$$;
