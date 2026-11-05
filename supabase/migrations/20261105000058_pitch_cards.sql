-- Pitch cards (Nov 3-5 2026): a dedicated place for business ideas, and for the people who want in.
--  * A pitch card is: the idea, its stage, the ask (partner, investor, developer...) and who you are.
--  * Routed, not broadcast: it reaches members whose "What I'm up for" fits the ask (money to invest,
--    looking for a co-founder, can build apps...), whose interests touch it, and the author's friends.
--    Anyone looking for a new business, partner or investment can also browse every pitch in their city.
--  * "Let's talk" opens a private chat with the author. No public counts: only the author sees who reached out.
--  * Contact details and links are blocked in pitches and pitch chats, same as ideas.
-- Safe to re-run.

create table if not exists public.pitches (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references public.profiles(id) on delete cascade,
  idea        text not null check (char_length(idea) between 10 and 500),
  stage       text not null check (stage in ('idea','building','launched','growing')),
  asks        text[] not null check (cardinality(asks) between 1 and 4),
  ask_note    text check (char_length(ask_note) <= 200),
  about       text not null check (char_length(about) between 10 and 300),
  words       text[] not null default '{}',
  city        text,
  status      text not null default 'live' check (status in ('live','closed','removed')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists pitches_created on public.pitches (created_at desc);
create index if not exists pitches_author on public.pitches (author_id, created_at desc);
create index if not exists pitches_words on public.pitches using gin (words);

create table if not exists public.pitch_threads (
  id          uuid primary key default gen_random_uuid(),
  pitch_id    uuid not null references public.pitches(id) on delete cascade,
  author_id   uuid not null references public.profiles(id) on delete cascade,
  other_id    uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (pitch_id, other_id),
  check (author_id <> other_id)
);

create table if not exists public.pitch_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.pitch_threads(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index if not exists pitch_messages_thread on public.pitch_messages (thread_id, created_at);

create table if not exists public.pitch_hidden (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  pitch_id   uuid not null references public.pitches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, pitch_id)
);

-- who was told about which pitch (so nobody is nudged twice, and each person at most every 3 days)
create table if not exists public.pitch_nudges (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  pitch_id   uuid not null references public.pitches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, pitch_id)
);

alter table public.pitches        enable row level security;  -- functions only
alter table public.pitch_threads  enable row level security;
alter table public.pitch_messages enable row level security;
alter table public.pitch_hidden   enable row level security;
alter table public.pitch_nudges   enable row level security;

-- ---------------------------------------------------------------------
-- The options (one place; the app reads them from pitch_options())
-- ---------------------------------------------------------------------
create or replace function public.pitch_options()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'stages', jsonb_build_array(
      jsonb_build_object('tag','idea',     'label','Just an idea'),
      jsonb_build_object('tag','building', 'label','Building it'),
      jsonb_build_object('tag','launched', 'label','Launched'),
      jsonb_build_object('tag','growing',  'label','Growing')),
    'asks', jsonb_build_array(
      jsonb_build_object('tag','partner',   'label','A partner'),
      jsonb_build_object('tag','investor',  'label','An investor'),
      jsonb_build_object('tag','developer', 'label','A developer'),
      jsonb_build_object('tag','designer',  'label','A designer'),
      jsonb_build_object('tag','marketing', 'label','Marketing or sales help'),
      jsonb_build_object('tag','trades',    'label','Trades or hands-on help'),
      jsonb_build_object('tag','mentor',    'label','A mentor'),
      jsonb_build_object('tag','team',      'label','People to hire'),
      jsonb_build_object('tag','buyer',     'label','A buyer for the business'),
      jsonb_build_object('tag','feedback',  'label','Honest feedback')));
$$;

create or replace function public.pitch_label(p_group text, p_tag text)
returns text language sql immutable as $$
  select e ->> 'label' from jsonb_array_elements(pitch_options() -> p_group) e where e ->> 'tag' = p_tag;
$$;

-- Which "What I'm up for" entries fit each ask, and the reason shown to that member
create or replace function public.pitch_ask_fits()
returns table (ask text, kind text, tag text, reason text)
language sql immutable as $$
  values
    ('partner',   'looking',   'cofounder',        'You''re looking for a co-founder'),
    ('partner',   'available', 'entrepreneurship', 'You''re up for entrepreneurship'),
    ('investor',  'can',       'funding',          'You have money to invest'),
    ('developer', 'can',       'build-apps',       'You build apps and software'),
    ('designer',  'can',       'design',           'You do design'),
    ('marketing', 'can',       'marketing',        'You do marketing'),
    ('marketing', 'can',       'sales',            'You do sales'),
    ('trades',    'can',       'trades',           'You do trades and building'),
    ('trades',    'can',       'welding',          'You weld'),
    ('trades',    'can',       'mechanic',         'You do mechanical work'),
    ('mentor',    'available', 'mentoring',        'You''re up for mentoring'),
    ('mentor',    'looking',   'mentee',           'You''re looking for someone to mentor'),
    ('team',      'looking',   'work',             'You''re looking for work'),
    ('buyer',     'looking',   'buy',              'You''re looking to buy');
$$;

-- The first reason a pitch's asks fit this member (null = no fit)
create or replace function public.pitch_fit(p_user uuid, p_asks text[])
returns text language sql stable security definer set search_path = public as $$
  select f.reason
  from pitch_ask_fits() f
  join profile_intents i on i.user_id = p_user and i.kind = f.kind and i.tag = f.tag
                        and (i.expires_at is null or i.expires_at > now())
  where f.ask = any(p_asks)
  order by array_position(p_asks, f.ask)
  limit 1;
$$;

-- ---------------------------------------------------------------------
-- Posting rules
-- ---------------------------------------------------------------------
create or replace function public.tg_pitch_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  p profiles;
  t text;
begin
  new.idea     := btrim(regexp_replace(coalesce(new.idea, ''), '\s+', ' ', 'g'));
  new.about    := btrim(regexp_replace(coalesce(new.about, ''), '\s+', ' ', 'g'));
  new.ask_note := nullif(btrim(regexp_replace(coalesce(new.ask_note, ''), '\s+', ' ', 'g')), '');
  if tg_op = 'UPDATE' and new.idea = old.idea and new.about = old.about
     and new.ask_note is not distinct from old.ask_note and new.stage = old.stage and new.asks = old.asks then
    return new;
  end if;
  select * into p from profiles where id = new.author_id;
  if p.status is distinct from 'active' then raise exception 'Finish setting up your profile to post a pitch.'; end if;
  if char_length(new.idea) < 10 then raise exception 'Tell people a little more about the idea.'; end if;
  if char_length(new.about) < 10 then raise exception 'Say a little about who you are.'; end if;
  if pitch_label('stages', new.stage) is null then raise exception 'Pick a stage.'; end if;
  new.asks := array(select distinct a from unnest(new.asks) a where pitch_label('asks', a) is not null);
  if cardinality(new.asks) = 0 then raise exception 'Pick what you''re looking for.'; end if;
  if cardinality(new.asks) > 4 then raise exception 'Pick up to 4 things you''re looking for.'; end if;
  foreach t in array array[new.idea, new.about, coalesce(new.ask_note, '')] loop
    if blocked_term_in(t) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
    if cardinality(detect_contact(t)) > 0 then
      raise exception 'Pitches can''t include contact info, links or social handles. People reach you here.';
    end if;
  end loop;
  if tg_op = 'INSERT' then
    if (select count(*) from pitches where author_id = new.author_id and created_at > now() - interval '24 hours') >= 3 then
      raise exception 'That''s 3 pitches today. Give these a chance to find their people.';
    end if;
    if (select count(*) from pitches where author_id = new.author_id and status = 'live') >= 3 then
      raise exception 'You have 3 live pitches. Close one before posting another.';
    end if;
    new.city := p.city;
  end if;
  new.words := idea_words(new.idea || ' ' || coalesce(new.ask_note, ''));
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists pitch_before on public.pitches;
create trigger pitch_before before insert or update of idea, about, ask_note, stage, asks on public.pitches
for each row execute function public.tg_pitch_before();

-- A new pitch quietly reaches up to 5 members in the city whose "What I'm up for" fits the ask
-- (each member hears about at most one pitch every 3 days)
create or replace function public.nudge_pitch(p_pitch uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  pt pitches;
  r record;
  n int := 0;
  v_name text;
begin
  select * into pt from pitches where id = p_pitch;
  if pt.id is null or pt.status <> 'live' then return 0; end if;
  select display_name into v_name from profiles where id = pt.author_id;
  for r in
    select u.id, pitch_fit(u.id, pt.asks) as why
    from profiles u
    where u.status = 'active' and u.id <> pt.author_id and u.city = pt.city
      and pitch_fit(u.id, pt.asks) is not null
      and not ideas_blocked(u.id, pt.author_id)
      and effective_tier(u.id) <> 'invisible'
      and not exists (select 1 from pitch_nudges x where x.user_id = u.id
                      and (x.pitch_id = pt.id or x.created_at > now() - interval '3 days'))
    order by u.last_active_at desc
    limit 5
  loop
    insert into pitch_nudges (user_id, pitch_id) values (r.id, pt.id) on conflict do nothing;
    perform notify(r.id, 'pitch_fit',
      v_name || ' posted a pitch and you might be who they''re looking for. ' || r.why || '. It''s in Pitches.');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Post, edit, close
-- ---------------------------------------------------------------------
create or replace function public.post_pitch(p_idea text, p_stage text, p_asks text[], p_about text, p_ask_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_id uuid;
begin
  insert into pitches (author_id, idea, stage, asks, about, ask_note)
  values (me, coalesce(p_idea, ''), coalesce(p_stage, ''), coalesce(p_asks, '{}'), coalesce(p_about, ''), p_ask_note)
  returning id into v_id;
  perform nudge_pitch(v_id);
  return v_id;
end $$;

create or replace function public.edit_pitch(p_pitch uuid, p_idea text, p_stage text, p_asks text[], p_about text, p_ask_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  update pitches set idea = coalesce(p_idea, ''), stage = coalesce(p_stage, ''), asks = coalesce(p_asks, '{}'),
                     about = coalesce(p_about, ''), ask_note = p_ask_note
   where id = p_pitch and author_id = me and status <> 'removed';
  if not found then raise exception 'That isn''t your pitch.'; end if;
end $$;

-- live | closed (no new chats; existing chats stay open) | removed
create or replace function public.set_pitch_status(p_pitch uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if p_status not in ('live','closed','removed') then raise exception 'Bad status'; end if;
  update pitches set status = p_status where id = p_pitch and author_id = me;
  if not found then raise exception 'That isn''t your pitch.'; end if;
end $$;

create or replace function public.hide_pitch(p_pitch uuid)
returns void language sql security definer set search_path = public as $$
  insert into pitch_hidden (user_id, pitch_id) select require_tester(), p_pitch on conflict do nothing;
$$;

-- ---------------------------------------------------------------------
-- Reading pitches
--  p_view: 'for_you' = pitches that fit you (asks you can answer, your interests, your friends),
--          plus the newest in your city so the section is never empty
--          'all'     = every live pitch in your city, newest first (optionally only one ask)
-- ---------------------------------------------------------------------
create or replace function public.get_pitches(p_view text default 'for_you', p_ask text default null, p_limit int default 40)
returns table (
  pitch_id uuid, author_id uuid, author_name text, author_photo text, idea text, stage text, stage_label text,
  asks text[], ask_labels text[], ask_note text, about text, created_at timestamptz, status text,
  mine boolean, why text, thread_id uuid)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  int_words text[];
  my_words text[];
begin
  select * into v from profiles where id = me;
  if effective_tier(me) = 'invisible' then return; end if;

  select idea_words(string_agg(t.name, ' ')) into int_words
  from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = me;
  select coalesce(array_agg(distinct w), '{}') into my_words
  from ideas i, unnest(i.words) w
  where i.author_id = me and i.status <> 'removed' and i.created_at > now() - interval '90 days';

  return query
  with base as (
    select pt.*,
           pt.author_id = me as is_mine,
           are_friends(me, pt.author_id) as friend,
           pitch_fit(me, pt.asks) as fit,
           word_overlap(pt.words, int_words) as int_ov,
           word_overlap(pt.words, my_words) as idea_ov,
           exists (select 1 from pitch_threads th where th.pitch_id = pt.id and th.other_id = me) as talking
    from pitches pt
    join profiles a on a.id = pt.author_id and a.status = 'active'
    where pt.created_at > now() - interval '120 days'
      and (pt.author_id = me and pt.status <> 'removed'
           or pt.status = 'live'
           or pt.status = 'closed' and exists (select 1 from pitch_threads th where th.pitch_id = pt.id and th.other_id = me))
      and (pt.author_id = me or (effective_tier(pt.author_id) <> 'invisible'
                                 and not ideas_blocked(me, pt.author_id)
                                 and not exists (select 1 from pitch_hidden h where h.user_id = me and h.pitch_id = pt.id)))
      and (p_ask is null or p_ask = any(pt.asks))
  ), scored as (
    select b.*,
           (b.is_mine or b.talking or b.fit is not null or b.friend or b.int_ov >= 1 or b.idea_ov >= 2) as relevant,
           ( case when b.fit is not null then 5 else 0 end
           + b.idea_ov * 1.5 + b.int_ov
           + case when b.friend then 2 else 0 end
           + case when b.city = v.city then 1 else 0 end
           - extract(epoch from (now() - b.created_at)) / 86400.0 / 7.0 ) as score
    from base b
    -- outside your city only when it truly fits you (or it's yours / a friend's / you're talking)
    where b.city is not distinct from v.city or b.is_mine or b.talking or b.friend or b.fit is not null
  ), picked as (
    select s.*, row_number() over (partition by s.relevant order by s.created_at desc) as filler_rank
    from scored s
  )
  select p.id, p.author_id, a.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.author_id and ph.position = 1 and ph.review_status = 'approved'),
         p.idea, p.stage, pitch_label('stages', p.stage),
         p.asks, array(select pitch_label('asks', x) from unnest(p.asks) x),
         p.ask_note, p.about, p.created_at, p.status, p.is_mine,
         case
           when p.is_mine then 'Your pitch'
           when p.fit is not null then p.fit
           when p.friend then 'Your friend'
           when p.idea_ov >= 2 then 'Close to an idea of yours'
           when p.int_ov >= 1 then 'Touches on what you''re into'
           when p.talking then 'You''re talking about this'
           else 'New in ' || coalesce((select c.name from cities c where c.slug = p.city), 'your city') end,
         (select th.id from pitch_threads th where th.pitch_id = p.id and th.other_id = me)
  from picked p
  join profiles a on a.id = p.author_id
  where case when coalesce(p_view, 'for_you') = 'all'
             then not p.is_mine
             else not p.is_mine and (p.relevant or p.filler_rank <= 8) end
  order by case when coalesce(p_view, 'for_you') = 'all' then 0 else (case when p.relevant then 1 else 0 end) end desc,
           case when coalesce(p_view, 'for_you') = 'all' then extract(epoch from p.created_at) else p.score end desc
  limit least(coalesce(p_limit, 40), 60);
end $$;

-- Your own pitches, with the people who reached out (only you see who; nobody sees a number)
create or replace function public.get_my_pitches()
returns table (pitch_id uuid, idea text, stage text, stage_label text, asks text[], ask_labels text[],
               ask_note text, about text, status text, created_at timestamptz, talkers jsonb)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select pt.id, pt.idea, pt.stage, pitch_label('stages', pt.stage), pt.asks,
         array(select pitch_label('asks', x) from unnest(pt.asks) x),
         pt.ask_note, pt.about, pt.status, pt.created_at,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'user_id', o.id, 'name', o.display_name, 'thread_id', th.id,
                     'photo', (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'))
                   order by th.created_at)
                   from pitch_threads th join profiles o on o.id = th.other_id and o.status = 'active'
                   where th.pitch_id = pt.id and not ideas_blocked(me, o.id)), '[]'::jsonb)
  from pitches pt
  where pt.author_id = me and pt.status <> 'removed'
  order by (pt.status = 'live') desc, pt.created_at desc;
end $$;

-- ---------------------------------------------------------------------
-- Let's talk: opens (or reuses) a private chat with the author
-- ---------------------------------------------------------------------
create or replace function public.talk_about_pitch(p_pitch uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  pt pitches;
  v_thread uuid;
  v_new boolean;
begin
  if (select status from profiles where id = me) <> 'active' then raise exception 'Finish setting up your profile first.'; end if;
  select * into pt from pitches where id = p_pitch;
  if pt.id is null or pt.status = 'removed' or ideas_blocked(me, pt.author_id) then raise exception 'That pitch is gone.'; end if;
  if pt.author_id = me then raise exception 'That''s your pitch.'; end if;
  v_new := not exists (select 1 from pitch_threads where pitch_id = pt.id and other_id = me);
  if v_new and pt.status = 'closed' then raise exception 'This pitch isn''t taking new conversations right now.'; end if;

  insert into pitch_threads (pitch_id, author_id, other_id) values (pt.id, pt.author_id, me)
  on conflict (pitch_id, other_id) do update set pitch_id = excluded.pitch_id
  returning id into v_thread;

  if v_new then
    perform notify(pt.author_id, 'pitch_talk',
      (select display_name from profiles where id = me) || ' wants to talk about your pitch: "'
      || left(pt.idea, 60) || case when char_length(pt.idea) > 60 then '…"' else '"' end);
  end if;
  return v_thread;
end $$;

create or replace function public.in_pitch_thread(p_thread uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from pitch_threads t where t.id = p_thread and p_user in (t.author_id, t.other_id));
$$;

create or replace function public.get_my_pitch_threads()
returns table (thread_id uuid, pitch_id uuid, pitch_idea text, other_id uuid, other_name text, other_photo text,
               i_am_author boolean, last_message text, last_message_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select t.id, pt.id, pt.idea, o.id, o.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'),
         t.author_id = me, lm.body, lm.created_at
  from pitch_threads t
  join pitches pt on pt.id = t.pitch_id
  join profiles o on o.id = case when t.author_id = me then t.other_id else t.author_id end
  left join lateral (select m.body, m.created_at from pitch_messages m
                     where m.thread_id = t.id order by m.created_at desc limit 1) lm on true
  where me in (t.author_id, t.other_id)
    and o.status = 'active'
    and not ideas_blocked(me, o.id)
  order by coalesce(lm.created_at, t.created_at) desc;
end $$;

create or replace function public.tg_pitch_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t pitch_threads;
  v_other uuid;
begin
  select * into t from pitch_threads where id = new.thread_id;
  if t.id is null or new.sender_id not in (t.author_id, t.other_id) then raise exception 'Not your conversation'; end if;
  v_other := case when new.sender_id = t.author_id then t.other_id else t.author_id end;
  if (select status from profiles where id = new.sender_id) <> 'active' then raise exception 'Account not active'; end if;
  if (select status from profiles where id = v_other) <> 'active' or ideas_blocked(new.sender_id, v_other) then
    raise exception 'This conversation is closed.';
  end if;
  new.body := btrim(new.body);
  if cardinality(detect_contact(new.body)) > 0 then
    raise exception 'Keep contact details for when you meet up. Plan a time to meet here.';
  end if;
  return new;
end $$;

drop trigger if exists pitch_message_before on public.pitch_messages;
create trigger pitch_message_before before insert on public.pitch_messages
for each row execute function public.tg_pitch_message_before();

create or replace function public.tg_pitch_message_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare t pitch_threads;
begin
  select * into t from pitch_threads where id = new.thread_id;
  if not exists (select 1 from pitch_messages m where m.thread_id = new.thread_id and m.id <> new.id
                 and m.sender_id = new.sender_id and m.created_at > now() - interval '30 minutes') then
    perform notify(case when new.sender_id = t.author_id then t.other_id else t.author_id end, 'pitch_message',
                   (select display_name from profiles where id = new.sender_id) || ' sent you a message about a pitch.');
  end if;
  return new;
end $$;

drop trigger if exists pitch_message_after on public.pitch_messages;
create trigger pitch_message_after after insert on public.pitch_messages
for each row execute function public.tg_pitch_message_after();

-- ---------------------------------------------------------------------
-- Security: chats are read/sent directly (live updates); everything else through functions
-- ---------------------------------------------------------------------
drop policy if exists "pitch messages read" on public.pitch_messages;
create policy "pitch messages read" on public.pitch_messages for select to authenticated
  using (public.is_tester() and public.in_pitch_thread(thread_id));
drop policy if exists "pitch messages send" on public.pitch_messages;
create policy "pitch messages send" on public.pitch_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_tester() and public.in_pitch_thread(thread_id));

do $$
declare f text;
begin
  foreach f in array array[
    'public.pitch_options()',
    'public.post_pitch(text,text,text[],text,text)', 'public.edit_pitch(uuid,text,text,text[],text,text)',
    'public.set_pitch_status(uuid,text)', 'public.hide_pitch(uuid)',
    'public.get_pitches(text,text,int)', 'public.get_my_pitches()',
    'public.talk_about_pitch(uuid)', 'public.in_pitch_thread(uuid,uuid)', 'public.get_my_pitch_threads()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.pitch_fit(uuid,text[])', 'public.nudge_pitch(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pitch_messages') then
    alter publication supabase_realtime add table public.pitch_messages;
  end if;
end $$;
