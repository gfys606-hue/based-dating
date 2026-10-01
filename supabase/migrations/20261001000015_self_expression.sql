-- Profile self-expression, three ways that aren't the usual written prompts:
--   1. "Unedited": a one-take voice answer (max 15 s) to a question the app picks. No re-roll, no re-record;
--      a new question is available once a day.
--   2. "Respectfully agree or disagree": one opinion you hold that people can agree or disagree with.
--      Viewers pick a side; only you see the totals.
--   3. "Lately": filled in automatically from what you actually do on Based (never written, never edited).

-- ---------- 1. Unedited ----------
create table if not exists public.voice_questions (
  id   serial primary key,
  text text not null unique
);
insert into public.voice_questions (text) values
  ('What did you get completely wrong about something, and when did you realize it?'),
  ('What''s a small thing that makes a day good for you?'),
  ('What''s something you''re weirdly good at?'),
  ('Describe your ideal Sunday, start to finish.'),
  ('What''s an opinion you changed in the last few years?'),
  ('What do your friends call you when you need help?'),
  ('What''s the last thing that made you laugh out loud?'),
  ('What are you working on getting better at right now?'),
  ('Where would you take someone to show them your city?'),
  ('What''s a hill you''d die on that doesn''t matter at all?'),
  ('What''s the best advice you''ve ignored?'),
  ('What does a good conversation feel like to you?'),
  ('What''s something you used to love that you''d like to get back into?'),
  ('Tell me about a place you felt completely at ease.'),
  ('What''s the most "you" thing you did this week?'),
  ('What''s a skill you''d learn if time weren''t a problem?'),
  ('What''s a rule you live by?'),
  ('What''s something people assume about you that isn''t true?'),
  ('What''s the best meal you''ve had, and who were you with?'),
  ('What would you do with a free afternoon tomorrow?')
on conflict (text) do nothing;

create table if not exists public.voice_answers (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  question_id  int not null references public.voice_questions(id),
  storage_path text not null,
  duration_ms  int not null check (duration_ms between 1000 and 16000),
  created_at   timestamptz not null default now()
);

-- The question you were given (so you can't keep drawing until you like one).
create table if not exists public.voice_draws (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  question_id int not null references public.voice_questions(id),
  drawn_at    timestamptz not null default now()
);

alter table public.voice_answers enable row level security; -- read through get_profile
alter table public.voice_draws   enable row level security; -- functions only

-- Give me a question. Same one for 10 minutes; a new one only after a day since your last answer.
create or replace function public.draw_voice_question()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  last_at timestamptz;
  d voice_draws;
  q voice_questions;
begin
  if me is null then raise exception 'Please log in again.'; end if;
  select created_at into last_at from voice_answers where user_id = me;
  if last_at is not null and last_at > now() - interval '24 hours' then
    raise exception 'You can answer a new question in % hours.',
      greatest(1, ceil(extract(epoch from last_at + interval '24 hours' - now()) / 3600))::int;
  end if;

  select * into d from voice_draws where user_id = me;
  if d.user_id is not null and d.drawn_at > now() - interval '10 minutes' then
    select * into q from voice_questions where id = d.question_id;
  else
    select * into q from voice_questions
     where id is distinct from (select question_id from voice_answers where user_id = me)
     order by random() limit 1;
    insert into voice_draws (user_id, question_id, drawn_at) values (me, q.id, now())
    on conflict (user_id) do update set question_id = excluded.question_id, drawn_at = now();
  end if;
  return jsonb_build_object('id', q.id, 'text', q.text);
end $$;

-- Save the one take. Returns the old recording's path so the app can delete the file.
create or replace function public.save_voice_answer(p_path text, p_duration_ms int)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  d voice_draws;
  old text;
begin
  select * into d from voice_draws where user_id = me;
  if d.user_id is null or d.drawn_at < now() - interval '15 minutes' then
    raise exception 'That question expired. Get a new one.';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> me::text then raise exception 'Invalid recording.'; end if;

  select storage_path into old from voice_answers where user_id = me;
  insert into voice_answers (user_id, question_id, storage_path, duration_ms, created_at)
  values (me, d.question_id, p_path, least(greatest(p_duration_ms, 1000), 16000), now())
  on conflict (user_id) do update set question_id = excluded.question_id, storage_path = excluded.storage_path,
                                      duration_ms = excluded.duration_ms, created_at = now();
  delete from voice_draws where user_id = me;
  return old;
end $$;

insert into storage.buckets (id, name, public) values ('voice', 'voice', false) on conflict (id) do nothing;
drop policy if exists "voice read" on storage.objects;
create policy "voice read" on storage.objects for select to authenticated using (bucket_id = 'voice');
drop policy if exists "voice upload" on storage.objects;
create policy "voice upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'voice' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "voice delete" on storage.objects;
create policy "voice delete" on storage.objects for delete to authenticated
  using (bucket_id = 'voice' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- 2. Respectfully agree or disagree ----------
create table if not exists public.stances (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  statement  text not null check (char_length(statement) between 8 and 140),
  updated_at timestamptz not null default now()
);
create table if not exists public.stance_reactions (
  stance_user uuid references public.profiles(id) on delete cascade,
  reactor     uuid references public.profiles(id) on delete cascade,
  verdict     text not null check (verdict in ('agree', 'disagree')),
  created_at  timestamptz not null default now(),
  primary key (stance_user, reactor)
);
alter table public.stances          enable row level security; -- functions only
alter table public.stance_reactions enable row level security;

-- Set (or clear, with an empty string) your stance. A new statement starts fresh.
create or replace function public.set_stance(p_statement text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  s text := btrim(coalesce(p_statement, ''));
begin
  if me is null then raise exception 'Please log in again.'; end if;
  if s = '' then
    delete from stances where user_id = me;
    delete from stance_reactions where stance_user = me;
    return;
  end if;
  if char_length(s) < 8 then raise exception 'Say a bit more (8+ characters).'; end if;
  if char_length(s) > 140 then raise exception 'Keep it under 140 characters.'; end if;
  if cardinality(detect_contact(s)) > 0 then raise exception 'Contact info, links and handles can''t go here.'; end if;

  if exists (select 1 from stances where user_id = me and statement <> s) then
    delete from stance_reactions where stance_user = me;
  end if;
  insert into stances (user_id, statement, updated_at) values (me, s, now())
  on conflict (user_id) do update set statement = excluded.statement, updated_at = now();
end $$;

-- Agree or respectfully disagree with someone's stance ('' clears your pick).
create or replace function public.react_stance(p_user uuid, p_verdict text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null or p_user = me then raise exception 'Not allowed.'; end if;
  if not exists (select 1 from stances where user_id = p_user) then raise exception 'Nothing to react to.'; end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    raise exception 'Not allowed.';
  end if;
  if coalesce(p_verdict, '') = '' then
    delete from stance_reactions where stance_user = p_user and reactor = me;
  elsif p_verdict in ('agree', 'disagree') then
    insert into stance_reactions (stance_user, reactor, verdict) values (p_user, me, p_verdict)
    on conflict (stance_user, reactor) do update set verdict = excluded.verdict, created_at = now();
  else
    raise exception 'Invalid choice.';
  end if;
end $$;

-- ---------- 3. Lately ----------
-- Up to 5 short lines built from real activity in the last 30 days. Search history is never used here.
create or replace function public.lately(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with topic_score as (
    select topic_id, sum(w) as score from (
      select po.topic_id, 3 as w from posts po
       where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 2 from comments c join posts po on po.id = c.post_id
       where c.author_id = p_user and c.status = 'visible' and c.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 1 from reactions r join posts po on po.id = r.post_id
       where r.user_id = p_user and r.created_at > now() - interval '30 days'
      union all
      select e.topic_id, 2 from event_rsvps r join events e on e.id = r.event_id
       where r.user_id = p_user and r.status = 'going' and e.topic_id is not null and r.created_at > now() - interval '30 days'
    ) x group by topic_id
  ),
  lines as (
    select 1 as ord, 'topic' as kind, 'Into ' || t.name || ' lately' as label, ts.score
      from topic_score ts join topics t on t.id = ts.topic_id
    union all
    select 2, 'event', 'Going to ' || e.title, 0
      from event_rsvps r join events e on e.id = r.event_id
     where r.user_id = p_user and r.status = 'going' and e.circle_id is null
       and e.starts_at between now() and now() + interval '30 days'
    union all
    select 3, 'posts', 'Posted ' || count(*) || ' times this month', 0
      from posts po where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
     having count(*) >= 2
    union all
    select 4, 'circles', 'In ' || count(*) || case when count(*) = 1 then ' circle' else ' circles' end, 0
      from circle_members cm where cm.user_id = p_user
     having count(*) >= 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'label', label) order by ord, score desc), '[]')
  from (select * from lines order by ord, score desc limit 5) l;
$$;

-- ---------- get_profile: add voice, stance and lately ----------
create or replace function public.get_profile(p_user uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p profiles;
  st stances;
  va record;
begin
  select * into p from profiles where id = p_user;
  if p.id is null or (p.status <> 'active' and p.id <> me) then return null; end if;
  if exists (select 1 from blocks b where (b.blocker = me and b.blocked = p_user) or (b.blocker = p_user and b.blocked = me)) then
    return null;
  end if;
  select * into st from stances where user_id = p_user;
  select a.storage_path, a.duration_ms, a.created_at, q.text as question into va
    from voice_answers a join voice_questions q on q.id = a.question_id where a.user_id = p_user;

  return jsonb_build_object(
    'id', p.id,
    'name', p.display_name,
    'age', extract(year from age(p.birthdate))::int,
    'is_me', p.id = me,
    'photos', (select coalesce(jsonb_agg(ph.storage_path order by ph.position), '[]')
                 from photos ph where ph.user_id = p.id and ph.review_status = 'approved'),
    'interests', (select coalesce(jsonb_agg(jsonb_build_object(
                     'name', t.name,
                     'shared', exists (select 1 from user_topics m where m.user_id = me and m.topic_id = t.id))
                   order by t.name), '[]')
                  from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = p.id),
    'recent_activity', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]') from (
                  select po.id, po.kind, po.body, t.name as topic, po.created_at
                  from posts po join topics t on t.id = po.topic_id
                  where po.author_id = p.id and po.status = 'visible'
                  order by po.created_at desc limit 10) x),
    'voice', case when va.storage_path is null then null else jsonb_build_object(
                 'question', va.question, 'path', va.storage_path, 'duration_ms', va.duration_ms,
                 'next_at', case when p.id = me then va.created_at + interval '24 hours' end) end,
    'stance', case when st.user_id is null then null else jsonb_build_object(
                 'statement', st.statement,
                 'my_verdict', (select verdict from stance_reactions where stance_user = p.id and reactor = me),
                 'agree', case when p.id = me then (select count(*) from stance_reactions where stance_user = p.id and verdict = 'agree') end,
                 'disagree', case when p.id = me then (select count(*) from stance_reactions where stance_user = p.id and verdict = 'disagree') end) end,
    'lately', lately(p.id)
  );
end $$;

revoke all on function public.draw_voice_question() from public, anon;
grant execute on function public.draw_voice_question() to authenticated;
revoke all on function public.save_voice_answer(text, int) from public, anon;
grant execute on function public.save_voice_answer(text, int) to authenticated;
revoke all on function public.set_stance(text) from public, anon;
grant execute on function public.set_stance(text) to authenticated;
revoke all on function public.react_stance(uuid, text) from public, anon;
grant execute on function public.react_stance(uuid, text) to authenticated;
revoke all on function public.lately(uuid) from public, anon, authenticated;
