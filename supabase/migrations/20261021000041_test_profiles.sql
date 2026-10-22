-- Test profiles (Oct 21 2026): 100 fake members in Calgary to try the app before real testers arrive.
--  * Marked is_test, so they're easy to find and remove (admin_remove_test_profiles()).
--  * They don't count toward the city's member cap.
--  * Their photos are drawn by the app (monogram cards), nothing is uploaded: storage_path starts with "test:".
--  * They can't sign in (no password, unusable email), they just populate Discover, the feed, Travel, etc.
-- Run once:  select admin_seed_test_profiles(100);
-- Remove:    select admin_remove_test_profiles();
-- Safe to re-run.

alter table public.profiles add column if not exists is_test boolean not null default false;

create or replace function public.city_members(p_city text)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from profiles
   where city = p_city and status in ('onboarding','active','paused') and not is_test;
$$;

create or replace function public.admin_seed_test_profiles(p_count int default 100)
returns int language plpgsql security definer set search_path = public, auth as $$
declare
  men   text[] := array['Liam','Noah','Owen','Mason','Ethan','Lucas','Logan','Jack','Ben','Carter','Wyatt','Hudson','Levi',
                        'Theo','Nolan','Cole','Reid','Grant','Beau','Miles','Jonah','Silas','Rhett','Tate','Dean'];
  women text[] := array['Emma','Olivia','Ava','Chloe','Maya','Nora','Leah','Hazel','Ivy','Zoe','Claire','Sadie','Ruby',
                        'Quinn','Tess','Mila','Jade','Elena','Piper','Willa','Iris','Nina','Brooke','Faye','Lena'];
  takes text[] := array[
    'How I paid off my truck in 18 months: a simple budget anyone can copy. Step by step below.',
    'Hiring a part-time bartender for weekend shifts in Inglewood. Message me if you or a friend is interested.',
    'Looking for a co-founder who knows mobile dev. I''m building a tool for local trades. Anyone want to build something?',
    'Lesson learned this year: say yes to the small invites. That''s where I met most of my real friends.',
    'Tips for your first time climbing at the gym: rent shoes, start on the 5s, and ask the regulars. They love helping.',
    'New coffee spot on 17th is great. Quiet enough to work, good pour-over.',
    'Anyone know a good mechanic in the NE? Honest ones only.',
    'Sunday run club is back. 7am at the Peace Bridge, all paces welcome.',
    'Honest update: moved here 3 months ago and still learning the city. Where do people actually go on Thursdays?',
    'Made a sourdough that didn''t collapse. Small wins.'];
  n int := least(greatest(coalesce(p_count, 100), 1), 500);
  i int;
  v_id uuid;
  v_gender text;
  v_name text;
  v_topics int[];
  made int := 0;
begin
  if auth.uid() is not null then perform require_admin(); end if;
  select array_agg(id) into v_topics from topics;

  for i in 1..n loop
    v_id := gen_random_uuid();
    v_gender := case when i % 2 = 0 then 'woman' else 'man' end;
    v_name := case when v_gender = 'man' then men[1 + (i * 7) % array_length(men, 1)]
                   else women[1 + (i * 11) % array_length(women, 1)] end
              || ' ' || chr(65 + (i * 5) % 26) || '.';

    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
            'test' || i || '-' || left(v_id::text, 8) || '@test.based-social.invalid', '', now(),
            '{"provider":"email","providers":["email"]}', '{"test":true}', now(), now(), '', '', '', '');

    insert into profiles (id, display_name, birthdate, gender, seeking, lat, lng, availability, feed_range,
                          status, selfie_verified, city, is_test, dating_on, dating_on_since, created_at, last_active_at)
    values (v_id, v_name,
            current_date - make_interval(years => 21 + (i * 3) % 18, days => (i * 37) % 300),
            v_gender,
            case when i % 10 = 0 then array['man','woman'] when v_gender = 'man' then array['woman'] else array['man'] end,
            51.0447 + (random() - 0.5) * 0.22, -114.0719 + (random() - 0.5) * 0.32,
            jsonb_build_object('fri', jsonb_build_array('evening'), 'sat', jsonb_build_array('afternoon','evening')),
            (array['local','region','region','province'])[1 + i % 4],
            'onboarding', true, 'calgary', true, i % 5 <> 0, case when i % 5 <> 0 then now() end,
            now() - make_interval(days => i % 30), now() - make_interval(hours => i % 72));

    -- 5-8 interests
    insert into user_topics (user_id, topic_id)
    select v_id, t from unnest(v_topics) t order by random() limit 5 + i % 4
    on conflict do nothing;

    -- 3 "photos" in one statement (the app draws them), then go live
    insert into photos (user_id, storage_path, position, review_status, shows_user, clear_face)
    values (v_id, 'test:' || v_id || ':1', 1, 'approved', true, true),
           (v_id, 'test:' || v_id || ':2', 2, 'approved', true, true),
           (v_id, 'test:' || v_id || ':3', 3, 'approved', true, true);
    update profiles set status = 'active' where id = v_id;

    -- some of them post
    if i % 3 = 0 then
      insert into posts (author_id, topic_id, kind, body)
      values (v_id, v_topics[1 + i % array_length(v_topics, 1)], 'take', takes[1 + i % array_length(takes, 1)]);
    end if;
    made := made + 1;
  end loop;
  delete from notifications where user_id in (select id from profiles where is_test);
  return made;
end $$;

create or replace function public.admin_remove_test_profiles()
returns int language plpgsql security definer set search_path = public, auth as $$
declare n int;
begin
  if auth.uid() is not null then perform require_admin(); end if;
  with gone as (
    delete from auth.users u using profiles p where p.id = u.id and p.is_test returning 1)
  select count(*)::int into n from gone;
  return n;
end $$;

revoke all on function public.admin_seed_test_profiles(int) from public, anon;
revoke all on function public.admin_remove_test_profiles() from public, anon;
grant execute on function public.admin_seed_test_profiles(int) to authenticated;
grant execute on function public.admin_remove_test_profiles() to authenticated;
