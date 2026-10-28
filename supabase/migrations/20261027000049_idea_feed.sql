-- Idea feed (Oct 27 2026): short idea posts whose only job is connecting the right people.
--  * Short text ideas (up to 280 characters). No likes, no counts anyone else can see.
--  * Routed, not broadcast: an idea goes to people whose own ideas or interests are close to it,
--    to the author's friends, and (to get things going) a small handful of new ideas from your city.
--  * "Same idea": when two people are thinking alike, each is nudged to connect, even without following.
--  * Replies are "I'm in" or "Let's talk"; both open a private chat with the author.
--  * The author can turn an idea into a group (a Herd); everyone who said "I'm in" gets an invite.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.ideas (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 3 and 280),
  words       text[] not null default '{}',   -- word stems, for matching ideas to people
  city        text,
  status      text not null default 'live' check (status in ('live','closed','removed')),
  group_id    uuid references public.circles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists ideas_created on public.ideas (created_at desc);
create index if not exists ideas_author on public.ideas (author_id, created_at desc);
create index if not exists ideas_words on public.ideas using gin (words);

create table if not exists public.idea_responses (
  idea_id     uuid not null references public.ideas(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('in','talk')),
  created_at  timestamptz not null default now(),
  primary key (idea_id, user_id)
);

-- "Not now" on a same-idea suggestion, or "hide this" in the feed
create table if not exists public.idea_dismissals (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  idea_id     uuid not null references public.ideas(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, idea_id)
);

create table if not exists public.idea_threads (
  id          uuid primary key default gen_random_uuid(),
  idea_id     uuid not null references public.ideas(id) on delete cascade,
  author_id   uuid not null references public.profiles(id) on delete cascade,
  other_id    uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (idea_id, other_id),
  check (author_id <> other_id)
);

create table if not exists public.idea_messages (
  id          uuid primary key default gen_random_uuid(),
  thread_id   uuid not null references public.idea_threads(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index if not exists idea_messages_thread on public.idea_messages (thread_id, created_at);

-- ---------------------------------------------------------------------
-- Word matching
-- ---------------------------------------------------------------------
-- The meaningful word stems in a piece of text ("building", "builds" -> "build"; "the", "and" dropped)
create or replace function public.idea_words(p text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct w order by w), '{}')
  from unnest(tsvector_to_array(to_tsvector('english'::regconfig, coalesce(p, '')))) w
  where char_length(w) >= 3
    -- everyday filler that says nothing about the idea itself
    and w <> all (array['anyon','anybodi','someon','somebodi','els','need','want','look','think','start',
                        'get','got','make','tri','idea','thing','someth','peopl','guy','realli','just',
                        'like','know','let','talk','also','would','could','go','new','good','great']);
$$;

create or replace function public.word_overlap(a text[], b text[])
returns int language sql immutable as $$
  select case when a is null or b is null then 0
              else cardinality(array(select unnest(a) intersect select unnest(b))) end;
$$;

-- Two ideas are "the same idea" when they share at least 2 stems and at least 40% of the shorter one
create or replace function public.same_idea(a text[], b text[])
returns boolean language sql immutable as $$
  select word_overlap(a, b) >= 2
     and word_overlap(a, b)::float8 / greatest(1, least(cardinality(a), cardinality(b))) >= 0.4;
$$;

-- keep stored stems in step with the matcher (re-runs)
update public.ideas set words = public.idea_words(body);

create or replace function public.ideas_blocked(p_x uuid, p_y uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks b where (b.blocker = p_x and b.blocked = p_y)
                                         or (b.blocker = p_y and b.blocked = p_x));
$$;

-- ---------------------------------------------------------------------
-- Posting rules
-- ---------------------------------------------------------------------
create or replace function public.tg_idea_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  new.body := btrim(regexp_replace(coalesce(new.body, ''), '\s+', ' ', 'g'));
  if tg_op = 'UPDATE' and new.body = old.body then return new; end if;
  select * into p from profiles where id = new.author_id;
  if p.status is distinct from 'active' then raise exception 'Finish setting up your profile to post ideas.'; end if;
  if char_length(new.body) < 3 then raise exception 'Say a little more.'; end if;
  if blocked_term_in(new.body) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
  if cardinality(detect_contact(new.body)) > 0 then
    raise exception 'Ideas can''t include contact info, links or social handles. People reach you here.';
  end if;
  if tg_op = 'INSERT' and (select count(*) from ideas where author_id = new.author_id
                           and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'That''s 5 ideas today. Give these a chance to find their people.';
  end if;
  new.words := idea_words(new.body);
  if tg_op = 'INSERT' then new.city := p.city; end if;
  return new;
end $$;

drop trigger if exists idea_before on public.ideas;
create trigger idea_before before insert or update of body on public.ideas
for each row execute function public.tg_idea_before();

-- A new idea quietly lets up to 3 people with the same idea know someone is thinking alike
create or replace function public.tg_idea_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if cardinality(new.words) < 2 then return new; end if;
  perform notify(x.author_id, 'same_idea', 'Someone on Based is thinking the same thing you are. Take a look in Ideas.')
  from (
    select distinct on (i.author_id) i.author_id, word_overlap(i.words, new.words) as ov
    from ideas i join profiles a on a.id = i.author_id and a.status = 'active'
    where i.author_id <> new.author_id
      and i.status = 'live'
      and i.created_at > now() - interval '90 days'
      and i.words && new.words
      and same_idea(i.words, new.words)
      and not ideas_blocked(i.author_id, new.author_id)
    order by i.author_id, word_overlap(i.words, new.words) desc
  ) x
  order by x.ov desc
  limit 3;
  return new;
end $$;

drop trigger if exists idea_after on public.ideas;
create trigger idea_after after insert on public.ideas
for each row execute function public.tg_idea_after();

-- ---------------------------------------------------------------------
-- Post, edit status
-- ---------------------------------------------------------------------
create or replace function public.post_idea(p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_id uuid;
begin
  insert into ideas (author_id, body) values (me, coalesce(p_body, '')) returning id into v_id;
  return v_id;
end $$;

-- live | closed (no new replies, stays visible to people already talking) | removed
create or replace function public.set_idea_status(p_idea uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if p_status not in ('live','closed','removed') then raise exception 'Bad status'; end if;
  update ideas set status = p_status where id = p_idea and author_id = me;
  if not found then raise exception 'That isn''t your idea.'; end if;
end $$;

create or replace function public.dismiss_idea(p_idea uuid)
returns void language sql security definer set search_path = public as $$
  insert into idea_dismissals (user_id, idea_id) select require_tester(), p_idea
  on conflict do nothing;
$$;

-- ---------------------------------------------------------------------
-- The feed: routed to the right people, not broadcast to the most
-- ---------------------------------------------------------------------
create or replace function public.get_ideas(p_before timestamptz default null, p_limit int default 30)
returns table (
  idea_id uuid, author_id uuid, author_name text, author_photo text, body text, created_at timestamptz,
  status text, mine boolean, why text, my_response text, thread_id uuid, group_id uuid, group_name text,
  responders jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  my_words text[];
  int_words text[];
begin
  select * into v from profiles where id = me;
  if effective_tier(me) = 'invisible' then return; end if;

  select coalesce(array_agg(distinct w), '{}') into my_words
  from ideas i, unnest(i.words) w
  where i.author_id = me and i.status <> 'removed' and i.created_at > now() - interval '90 days';

  select idea_words(string_agg(t.name, ' ')) into int_words
  from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = me;

  return query
  with base as (
    select i.*,
           i.author_id = me as is_mine,
           are_friends(me, i.author_id) as friend,
           word_overlap(i.words, my_words) as close_ov,
           same_idea(i.words, my_words) as close_same,
           word_overlap(i.words, int_words) as int_ov,
           exists (select 1 from idea_responses r where r.idea_id = i.id and r.user_id = me) as responded
    from ideas i
    join profiles a on a.id = i.author_id and a.status = 'active'
    where (p_before is null or i.created_at < p_before)
      and i.created_at > now() - interval '60 days'
      and (i.author_id = me and i.status <> 'removed'
           or i.status = 'live'
           or i.status = 'closed' and exists (select 1 from idea_threads t where t.idea_id = i.id and t.other_id = me))
      and (i.author_id = me or (effective_tier(i.author_id) <> 'invisible'
                                and not ideas_blocked(me, i.author_id)
                                and not exists (select 1 from idea_dismissals d where d.user_id = me and d.idea_id = i.id)))
  ), scored as (
    select b.*,
           (b.is_mine or b.friend or b.responded or b.close_ov >= 2 or b.int_ov >= 1) as relevant,
           ( case when b.close_same then 6 else b.close_ov * 1.5 end
           + b.int_ov * 1.0
           + case when b.friend then 2.0 else 0 end
           + case when b.responded then 1.0 else 0 end
           + case when b.city = v.city then 0.5 else 0 end
           - extract(epoch from (now() - b.created_at)) / 86400.0 / 3.0 ) as score
    from base b
  ), picked as (
    select s.*,
           row_number() over (partition by s.relevant order by s.created_at desc) as filler_rank
    from scored s
    where s.relevant
       or (s.city = v.city and s.created_at > now() - interval '7 days')
  )
  select p.id, p.author_id, a.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.author_id and ph.position = 1 and ph.review_status = 'approved'),
         p.body, p.created_at, p.status, p.is_mine,
         case
           when p.is_mine then 'Your idea'
           when p.close_same then 'Close to an idea of yours'
           when p.friend then 'Your friend'
           when p.close_ov >= 2 then 'Touches on something you posted'
           when p.int_ov >= 1 then 'Fits what you''re into'
           when p.responded then 'You''re in on this'
           else 'New in ' || coalesce((select c.name from cities c where c.slug = p.city), 'your city') end,
         (select r.kind from idea_responses r where r.idea_id = p.id and r.user_id = me),
         (select t.id from idea_threads t where t.idea_id = p.id and t.other_id = me),
         p.group_id,
         (select c.name from circles c where c.id = p.group_id),
         case when p.is_mine then
           coalesce((select jsonb_agg(jsonb_build_object(
                       'user_id', r.user_id, 'name', u.display_name, 'kind', r.kind,
                       'photo', (select ph.storage_path from photos ph where ph.user_id = r.user_id and ph.position = 1 and ph.review_status = 'approved'),
                       'thread_id', (select t.id from idea_threads t where t.idea_id = p.id and t.other_id = r.user_id))
                     order by r.created_at)
                     from idea_responses r join profiles u on u.id = r.user_id and u.status = 'active'
                     where r.idea_id = p.id), '[]'::jsonb)
         else null end
  from picked p
  join profiles a on a.id = p.author_id
  where p.relevant or p.filler_rank <= 10
  order by p.relevant desc, p.score desc, p.created_at desc
  limit least(coalesce(p_limit, 30), 50);
end $$;

-- ---------------------------------------------------------------------
-- "Same idea": people thinking what you're thinking
-- ---------------------------------------------------------------------
create or replace function public.get_same_ideas()
returns table (my_idea_id uuid, my_body text, idea_id uuid, author_id uuid, author_name text,
               author_photo text, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select x.mine_id, x.mine_body, x.id, x.author_id, a.display_name,
         (select ph.storage_path from photos ph where ph.user_id = x.author_id and ph.position = 1 and ph.review_status = 'approved'),
         x.body, x.created_at
  from (
    select distinct on (o.author_id) m.id as mine_id, m.body as mine_body, o.id, o.author_id, o.body, o.created_at,
           word_overlap(o.words, m.words) as ov
    from ideas m
    join ideas o on o.author_id <> me and o.status = 'live' and o.words && m.words and same_idea(o.words, m.words)
    where m.author_id = me and m.status = 'live' and m.created_at > now() - interval '90 days'
      and o.created_at > now() - interval '90 days'
      and not ideas_blocked(me, o.author_id)
      and effective_tier(o.author_id) <> 'invisible'
      and not exists (select 1 from idea_dismissals d where d.user_id = me and d.idea_id = o.id)
      and not exists (select 1 from idea_responses r where r.idea_id = o.id and r.user_id = me)
      -- already talking about either idea? then no need to nudge
      and not exists (select 1 from idea_threads t
                      where (t.author_id = me and t.other_id = o.author_id)
                         or (t.author_id = o.author_id and t.other_id = me))
    order by o.author_id, word_overlap(o.words, m.words) desc, o.created_at desc
  ) x
  join profiles a on a.id = x.author_id and a.status = 'active'
  order by x.ov desc, x.created_at desc
  limit 10;
end $$;

-- ---------------------------------------------------------------------
-- I'm in / Let's talk: opens (or reuses) a private chat with the author
-- ---------------------------------------------------------------------
create or replace function public.respond_to_idea(p_idea uuid, p_kind text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  i ideas;
  v_new boolean;
  v_thread uuid;
  v_name text;
begin
  if p_kind not in ('in','talk') then raise exception 'Bad reply'; end if;
  if (select status from profiles where id = me) <> 'active' then raise exception 'Finish setting up your profile first.'; end if;
  select * into i from ideas where id = p_idea;
  if i.id is null or i.status = 'removed' then raise exception 'That idea is gone.'; end if;
  if i.author_id = me then raise exception 'That''s your idea.'; end if;
  if ideas_blocked(me, i.author_id) then raise exception 'That idea is gone.'; end if;
  if i.status = 'closed' and not exists (select 1 from idea_responses where idea_id = i.id and user_id = me) then
    raise exception 'This idea isn''t taking new people right now.';
  end if;

  v_new := not exists (select 1 from idea_responses where idea_id = i.id and user_id = me);
  insert into idea_responses (idea_id, user_id, kind) values (i.id, me, p_kind)
  on conflict (idea_id, user_id) do update set kind = excluded.kind;

  insert into idea_threads (idea_id, author_id, other_id) values (i.id, i.author_id, me)
  on conflict (idea_id, other_id) do update set idea_id = excluded.idea_id
  returning id into v_thread;

  if v_new then
    select display_name into v_name from profiles where id = me;
    perform notify(i.author_id, 'idea_reply',
      v_name || case when p_kind = 'in' then ' is in on your idea: "' else ' wants to talk about your idea: "' end
      || left(i.body, 60) || case when char_length(i.body) > 60 then '…"' else '"' end);
  end if;
  return v_thread;
end $$;

create or replace function public.withdraw_idea_response(p_idea uuid)
returns void language sql security definer set search_path = public as $$
  delete from idea_responses where idea_id = p_idea and user_id = require_tester();
$$;

-- ---------------------------------------------------------------------
-- Idea -> group: a Herd for the idea; everyone who said "I'm in" gets an invite
-- ---------------------------------------------------------------------
create or replace function public.idea_to_group(p_idea uuid, p_name text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  i ideas;
  v_circle uuid;
  v_name text;
  v_me text;
  r record;
  n int := 0;
begin
  select * into i from ideas where id = p_idea for update;
  if i.id is null or i.author_id <> me then raise exception 'That isn''t your idea.'; end if;
  if i.group_id is not null and exists (select 1 from circles where id = i.group_id) then return i.group_id; end if;

  v_name := left(btrim(coalesce(nullif(btrim(p_name), ''), i.body)), 60);
  v_circle := create_circle(v_name);
  update ideas set group_id = v_circle where id = i.id;
  select display_name into v_me from profiles where id = me;

  for r in
    select ir.user_id from idea_responses ir join profiles u on u.id = ir.user_id and u.status = 'active'
    where ir.idea_id = i.id and ir.kind = 'in' and not ideas_blocked(me, ir.user_id)
    order by ir.created_at
  loop
    exit when n >= 29;   -- herds hold 30
    insert into circle_nominations (circle_id, nominee, nominated_by, note, status, decided_at)
    values (v_circle, r.user_id, me, 'From the idea: ' || left(i.body, 150), 'invited', now())
    on conflict do nothing;
    perform notify(r.user_id, 'idea_group', v_me || ' started a group for an idea you''re in on. Your invite is in Herd.');
    n := n + 1;
  end loop;
  return v_circle;
end $$;

-- People who said "I'm in" after the group started: the author can invite them too
create or replace function public.invite_to_idea_group(p_idea uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  i ideas;
begin
  select * into i from ideas where id = p_idea;
  if i.id is null or i.author_id <> me then raise exception 'That isn''t your idea.'; end if;
  if i.group_id is null then raise exception 'Start the group first.'; end if;
  if not exists (select 1 from idea_responses where idea_id = i.id and user_id = p_user) then
    raise exception 'They haven''t replied to this idea.';
  end if;
  if exists (select 1 from circle_members where circle_id = i.group_id and user_id = p_user) then return; end if;
  insert into circle_nominations (circle_id, nominee, nominated_by, note, status, decided_at)
  values (i.group_id, p_user, me, 'From the idea: ' || left(i.body, 150), 'invited', now())
  on conflict do nothing;
  perform notify(p_user, 'idea_group',
    (select display_name from profiles where id = me) || ' invited you to the group for their idea. Your invite is in Herd.');
end $$;

-- ---------------------------------------------------------------------
-- Idea chats
-- ---------------------------------------------------------------------
create or replace function public.in_idea_thread(p_thread uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from idea_threads t where t.id = p_thread and p_user in (t.author_id, t.other_id));
$$;

create or replace function public.get_my_idea_threads()
returns table (thread_id uuid, idea_id uuid, idea_body text, other_id uuid, other_name text, other_photo text,
               i_am_author boolean, last_message text, last_message_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select t.id, i.id, i.body, o.id, o.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.id and ph.position = 1 and ph.review_status = 'approved'),
         t.author_id = me, lm.body, lm.created_at
  from idea_threads t
  join ideas i on i.id = t.idea_id
  join profiles o on o.id = case when t.author_id = me then t.other_id else t.author_id end
  left join lateral (select m.body, m.created_at from idea_messages m
                     where m.thread_id = t.id order by m.created_at desc limit 1) lm on true
  where me in (t.author_id, t.other_id)
    and o.status = 'active'
    and not ideas_blocked(me, o.id)
  order by coalesce(lm.created_at, t.created_at) desc;
end $$;

create or replace function public.tg_idea_message_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t idea_threads;
  v_other uuid;
begin
  select * into t from idea_threads where id = new.thread_id;
  if t.id is null or new.sender_id not in (t.author_id, t.other_id) then raise exception 'Not your conversation'; end if;
  v_other := case when new.sender_id = t.author_id then t.other_id else t.author_id end;
  if (select status from profiles where id = new.sender_id) <> 'active' then raise exception 'Account not active'; end if;
  if (select status from profiles where id = v_other) <> 'active' or ideas_blocked(new.sender_id, v_other) then
    raise exception 'This conversation is closed.';
  end if;
  new.body := btrim(new.body);
  if cardinality(detect_contact(new.body)) > 0 then
    raise exception 'Keep contact details for when you meet up. Plan it here, or start a group.';
  end if;
  return new;
end $$;

drop trigger if exists idea_message_before on public.idea_messages;
create trigger idea_message_before before insert on public.idea_messages
for each row execute function public.tg_idea_message_before();

create or replace function public.tg_idea_message_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare t idea_threads;
begin
  select * into t from idea_threads where id = new.thread_id;
  -- one heads-up per quiet stretch, not one per message
  if not exists (select 1 from idea_messages m where m.thread_id = new.thread_id and m.id <> new.id
                 and m.sender_id = new.sender_id and m.created_at > now() - interval '30 minutes') then
    perform notify(case when new.sender_id = t.author_id then t.other_id else t.author_id end, 'idea_message',
                   (select display_name from profiles where id = new.sender_id) || ' sent you a message about an idea.');
  end if;
  return new;
end $$;

drop trigger if exists idea_message_after on public.idea_messages;
create trigger idea_message_after after insert on public.idea_messages
for each row execute function public.tg_idea_message_after();

-- ---------------------------------------------------------------------
-- Security: chats are read/sent directly (live updates); everything else through functions
-- ---------------------------------------------------------------------
alter table public.ideas           enable row level security;
alter table public.idea_responses  enable row level security;
alter table public.idea_dismissals enable row level security;
alter table public.idea_threads    enable row level security;
alter table public.idea_messages   enable row level security;

drop policy if exists "idea messages read" on public.idea_messages;
create policy "idea messages read" on public.idea_messages for select to authenticated
  using (public.is_tester() and public.in_idea_thread(thread_id));
drop policy if exists "idea messages send" on public.idea_messages;
create policy "idea messages send" on public.idea_messages for insert to authenticated
  with check (sender_id = auth.uid() and public.is_tester() and public.in_idea_thread(thread_id));

do $$
declare f text;
begin
  foreach f in array array[
    'public.post_idea(text)', 'public.set_idea_status(uuid,text)', 'public.dismiss_idea(uuid)',
    'public.get_ideas(timestamptz,int)', 'public.get_same_ideas()',
    'public.respond_to_idea(uuid,text)', 'public.withdraw_idea_response(uuid)',
    'public.idea_to_group(uuid,text)', 'public.invite_to_idea_group(uuid,uuid)',
    'public.in_idea_thread(uuid,uuid)', 'public.get_my_idea_threads()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.ideas_blocked(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- Live chat updates
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'idea_messages') then
    alter publication supabase_realtime add table public.idea_messages;
  end if;
end $$;
