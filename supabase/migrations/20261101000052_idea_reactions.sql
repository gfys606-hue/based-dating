-- Idea reactions + open conversations (Nov 1 2026), on both people's ideas and Based-pick cards.
--  * Back it (the like): one tap. A reason is optional: I'd join / I know someone / I've done this / I'd pay for it.
--    Reasons give the back more routing weight. "I'd join" also says "I'm in" (opens the chat with the author);
--    "I know someone" lets you tag a friend, and the idea goes to them.
--  * Push back (the dislike): one tap. A reason is optional (Been done / Too costly / Bad timing / Needs a twist /
--    Not realistic), and so is a one-line note. A push back with a reason or note goes into the conversation.
--  * Not for me: the existing "Hide this" / hide_idea_card. Silent, only tunes your own feed.
--  * 5 backs a day (rolling 24 hours). Push backs are unlimited.
--  * No counts anywhere. The author sees who backed or pushed back and why, plus a private temperature.
--  * Every idea and card has an open conversation anyone who can see it can read. To write in it you join;
--    members can see who else is in. The author can turn the conversation into a group (Herd).
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.idea_reactions (
  target_kind  text not null check (target_kind in ('idea','card')),
  target_id    uuid not null,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  reaction     text not null check (reaction in ('back','push')),
  reason       text check (reason is null or reason in
                 ('join','know','done','pay','been_done','costly','timing','twist','unrealistic')),
  note         text check (note is null or char_length(note) between 1 and 200),
  tagged_user  uuid references public.profiles(id) on delete set null,
  backed_at    timestamptz,   -- when it became a back (for the 5-a-day limit)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (target_kind, target_id, user_id),
  check (reaction = 'back' and (reason is null or reason in ('join','know','done','pay'))
      or reaction = 'push' and (reason is null or reason in ('been_done','costly','timing','twist','unrealistic')))
);
create index if not exists idea_reactions_user on public.idea_reactions (user_id, backed_at desc);
create index if not exists idea_reactions_tag on public.idea_reactions (tagged_user) where tagged_user is not null;

create table if not exists public.idea_convo_members (
  target_kind text not null check (target_kind in ('idea','card')),
  target_id   uuid not null,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  joined_at   timestamptz not null default now(),
  primary key (target_kind, target_id, user_id)
);
create index if not exists idea_convo_members_user on public.idea_convo_members (user_id, joined_at desc);

create table if not exists public.idea_convo_posts (
  id          uuid primary key default gen_random_uuid(),
  target_kind text not null check (target_kind in ('idea','card')),
  target_id   uuid not null,
  author_id   uuid not null references public.profiles(id) on delete cascade,
  kind        text not null default 'comment' check (kind in ('comment','push')),
  reason      text,
  body        text check (body is null or char_length(body) between 1 and 500),
  removed     boolean not null default false,
  created_at  timestamptz not null default now(),
  check (body is not null or reason is not null)
);
create index if not exists idea_convo_posts_target on public.idea_convo_posts (target_kind, target_id, created_at);

alter table public.idea_reactions     enable row level security;
alter table public.idea_convo_members enable row level security;
alter table public.idea_convo_posts   enable row level security;

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.reaction_label(p_reason text)
returns text language sql immutable as $$
  select case p_reason
    when 'join' then 'I''d join' when 'know' then 'I know someone' when 'done' then 'I''ve done this'
    when 'pay' then 'I''d pay for it' when 'been_done' then 'Been done' when 'costly' then 'Too costly'
    when 'timing' then 'Bad timing' when 'twist' then 'Needs a twist' when 'unrealistic' then 'Not realistic'
    else null end;
$$;

-- Reason-weighted backs: a back with a real intent counts more than a plain tap. Push backs don't subtract.
create or replace function public.idea_heat(p_kind text, p_id uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(case r.reason when 'join' then 3 when 'pay' then 3 when 'know' then 2 when 'done' then 2 else 1 end), 0)
  from idea_reactions r join profiles u on u.id = r.user_id and u.status = 'active'
  where r.target_kind = p_kind and r.target_id = p_id and r.reaction = 'back';
$$;

create or replace function public.heat_label(p numeric)
returns text language sql immutable as $$
  select case when p >= 10 then 'hot' when p >= 4 then 'warm' when p >= 1 then 'warming' else 'cold' end;
$$;

-- The author of an idea (null for a card). Raises when it's gone or you can't see it.
create or replace function public.idea_target_author(p_kind text, p_id uuid, p_me uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare i ideas;
begin
  if p_kind = 'card' then
    if not exists (select 1 from idea_cards where id = p_id and status = 'live') then raise exception 'That card is gone.'; end if;
    return null;
  elsif p_kind = 'idea' then
    select * into i from ideas where id = p_id;
    if i.id is null or i.status = 'removed' or ideas_blocked(p_me, i.author_id)
       or (select status from profiles where id = i.author_id) is distinct from 'active' then
      raise exception 'That idea is gone.';
    end if;
    return i.author_id;
  end if;
  raise exception 'Bad target';
end $$;

create or replace function public.idea_target_title(p_kind text, p_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select left(case when p_kind = 'card' then (select title from idea_cards where id = p_id)
                   else (select body from ideas where id = p_id) end, 60);
$$;

create or replace function public.in_idea_convo(p_kind text, p_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from idea_convo_members m
                 where m.target_kind = p_kind and m.target_id = p_id and m.user_id = p_user);
$$;

-- Join quietly (used by push backs with a note and "I'd join" on cards). The author of an idea is always in.
create or replace function public.add_to_idea_convo(p_kind text, p_id uuid, p_user uuid)
returns void language sql security definer set search_path = public as $$
  insert into idea_convo_members (target_kind, target_id, user_id) values (p_kind, p_id, p_user)
  on conflict do nothing;
$$;

-- One heads-up per person per half hour, not one per comment
create or replace function public.notify_idea_convo(p_kind text, p_id uuid, p_from uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_author uuid := case when p_kind = 'idea' then (select author_id from ideas where id = p_id) end;
begin
  perform notify(x.uid, 'idea_convo', p_text)
  from (
    select m.user_id as uid from idea_convo_members m
    where m.target_kind = p_kind and m.target_id = p_id
    union
    select v_author where v_author is not null
  ) x
  join profiles u on u.id = x.uid and u.status = 'active'
  where x.uid <> p_from
    and not ideas_blocked(x.uid, p_from)
    and not exists (select 1 from notifications n where n.user_id = x.uid and n.kind = 'idea_convo'
                    and n.created_at > now() - interval '30 minutes');
end $$;

-- ---------------------------------------------------------------------
-- Back it / Push back
-- ---------------------------------------------------------------------
-- p_reaction: 'back' | 'push' | null (take it back). Returns {thread_id, backs_left}.
create or replace function public.react_to_idea(p_kind text, p_id uuid, p_reaction text,
                                                p_reason text default null, p_note text default null,
                                                p_tag uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_author uuid;
  v_old idea_reactions;
  v_note text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '\s+', ' ', 'g')), '');
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_tag uuid := p_tag;
  v_thread uuid;
  v_name text;
  v_title text;
  v_changed boolean;
begin
  if (select status from profiles where id = me) is distinct from 'active' then
    raise exception 'Finish setting up your profile first.';
  end if;
  v_author := idea_target_author(p_kind, p_id, me);
  if v_author = me then raise exception 'That''s your idea.'; end if;

  select * into v_old from idea_reactions where target_kind = p_kind and target_id = p_id and user_id = me;

  if p_reaction is null then
    delete from idea_reactions where target_kind = p_kind and target_id = p_id and user_id = me;
    return jsonb_build_object('thread_id', null, 'backs_left', backs_left(me));
  end if;

  if p_reaction not in ('back','push') then raise exception 'Bad reaction'; end if;
  if v_reason is not null and (p_reaction = 'back' and v_reason not in ('join','know','done','pay')
                            or p_reaction = 'push' and v_reason not in ('been_done','costly','timing','twist','unrealistic')) then
    raise exception 'Bad reason';
  end if;
  if p_reaction = 'back' then v_note := null; end if;
  if v_reason is distinct from 'know' then v_tag := null; end if;

  if v_note is not null then
    if char_length(v_note) > 200 then raise exception 'Keep it to one line.'; end if;
    if blocked_term_in(v_note) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
    if cardinality(detect_contact(v_note)) > 0 then raise exception 'Notes can''t include contact info, links or handles.'; end if;
  end if;
  if v_tag is not null then
    if v_tag = me or v_tag = v_author then v_tag := null;
    elsif not are_friends(me, v_tag) then raise exception 'You can tag friends only.';
    end if;
  end if;

  -- 5 backs a day (rolling 24 hours); changing the reason on a back you already gave is free
  if p_reaction = 'back' and v_old.reaction is distinct from 'back' and backs_left(me) <= 0 then
    raise exception 'You''ve used your 5 backs for today. They come back as the day rolls over.';
  end if;

  v_changed := v_old.reaction is distinct from p_reaction or v_old.reason is distinct from v_reason
               or v_old.note is distinct from v_note or v_old.tagged_user is distinct from v_tag;

  insert into idea_reactions (target_kind, target_id, user_id, reaction, reason, note, tagged_user, backed_at)
  values (p_kind, p_id, me, p_reaction, v_reason, v_note, v_tag, case when p_reaction = 'back' then now() end)
  on conflict (target_kind, target_id, user_id) do update
     set reaction = excluded.reaction, reason = excluded.reason, note = excluded.note,
         tagged_user = excluded.tagged_user, updated_at = now(),
         backed_at = case when excluded.reaction <> 'back' then null
                          when idea_reactions.reaction = 'back' then idea_reactions.backed_at
                          else now() end;

  if not v_changed then
    return jsonb_build_object('thread_id', null, 'backs_left', backs_left(me));
  end if;

  select display_name into v_name from profiles where id = me;
  v_title := idea_target_title(p_kind, p_id);

  -- "I'd join": on an idea it's an "I'm in" (chat with the author); on a card you join its conversation
  if p_reaction = 'back' and v_reason = 'join' then
    if p_kind = 'idea' then
      begin
        v_thread := respond_to_idea(p_id, 'in');
      exception when others then v_thread := null;   -- e.g. closed to new people; the back still counts
      end;
    else
      perform add_to_idea_convo(p_kind, p_id, me);
    end if;
  end if;

  -- "I know someone": it goes to the friend you tagged
  if v_tag is not null and v_tag is distinct from v_old.tagged_user then
    if p_kind = 'card' then
      insert into card_shown (user_id, card_id, shown_on) values (v_tag, p_id, current_date)
      on conflict (user_id, card_id) do update set shown_on = current_date where not card_shown.hidden;
    end if;
    perform notify(v_tag, 'idea_tag', v_name || ' thinks you''d be into this: "' || v_title || '". It''s in Ideas.');
  end if;

  -- A push back with a reason or a note goes into the conversation (and joins you to it)
  if p_reaction = 'push' and (v_reason is not null or v_note is not null) then
    perform add_to_idea_convo(p_kind, p_id, me);
    insert into idea_convo_posts (target_kind, target_id, author_id, kind, reason, body)
    values (p_kind, p_id, me, 'push', v_reason, v_note);
    perform notify_idea_convo(p_kind, p_id, me, v_name || ' pushed back on "' || v_title || '". See the conversation in Ideas.');
  end if;

  -- The author hears about backs with a reason (an "I'd join" already told them)
  if v_author is not null and p_reaction = 'back' and v_reason in ('know','done','pay')
     and v_old.reason is distinct from v_reason then
    perform notify(v_author, 'idea_back', v_name || ' backed your idea (' || reaction_label(v_reason) || '): "' || v_title || '"');
  end if;

  return jsonb_build_object('thread_id', v_thread, 'backs_left', backs_left(me));
end $$;

create or replace function public.backs_left(p_user uuid default auth.uid())
returns int language sql stable security definer set search_path = public as $$
  select greatest(0, 5 - (select count(*)::int from idea_reactions
                          where user_id = p_user and reaction = 'back' and backed_at > now() - interval '24 hours'));
$$;

create or replace function public.my_backs_left()
returns int language sql stable security definer set search_path = public as $$
  select backs_left(require_tester());
$$;

-- ---------------------------------------------------------------------
-- Reaction state for a set of ideas or cards (the app asks for what's on screen)
-- ---------------------------------------------------------------------
create or replace function public.get_idea_reactions(p_kind text, p_ids uuid[])
returns table (target_id uuid, my_reaction text, my_reason text, my_note text, joined boolean,
               has_convo boolean, temperature text, reactors jsonb)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  return query
  select t.id,
         r.reaction, r.reason, r.note,
         coalesce(in_idea_convo(p_kind, t.id, me) or (p_kind = 'idea' and i.author_id = me), false),
         exists (select 1 from idea_convo_posts c where c.target_kind = p_kind and c.target_id = t.id and not c.removed),
         case when p_kind = 'idea' and i.author_id = me then heat_label(idea_heat(p_kind, t.id)) end,
         case when p_kind = 'idea' and i.author_id = me then
           coalesce((select jsonb_agg(jsonb_build_object(
                       'user_id', x.user_id, 'name', u.display_name, 'reaction', x.reaction,
                       'reason', reaction_label(x.reason), 'note', x.note,
                       'photo', (select ph.storage_path from photos ph where ph.user_id = x.user_id and ph.position = 1 and ph.review_status = 'approved'),
                       'thread_id', (select th.id from idea_threads th where th.idea_id = t.id and th.other_id = x.user_id))
                     order by x.reaction, x.updated_at desc)
                     from idea_reactions x join profiles u on u.id = x.user_id and u.status = 'active'
                     where x.target_kind = 'idea' and x.target_id = t.id and not ideas_blocked(me, x.user_id)),
                    '[]'::jsonb)
         end
  from unnest(coalesce(p_ids, '{}')) as t(id)
  left join ideas i on p_kind = 'idea' and i.id = t.id
  left join idea_reactions r on r.target_kind = p_kind and r.target_id = t.id and r.user_id = me;
end $$;

-- ---------------------------------------------------------------------
-- Conversations: anyone who can see the idea reads it; you join to write
-- ---------------------------------------------------------------------
create or replace function public.join_idea_convo(p_kind text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if (select status from profiles where id = me) is distinct from 'active' then
    raise exception 'Finish setting up your profile first.';
  end if;
  perform idea_target_author(p_kind, p_id, me);
  if p_kind = 'idea' and (select status from ideas where id = p_id) = 'closed'
     and (select author_id from ideas where id = p_id) <> me
     and not in_idea_convo(p_kind, p_id, me) then
    raise exception 'This idea isn''t taking new people right now.';
  end if;
  perform add_to_idea_convo(p_kind, p_id, me);
end $$;

create or replace function public.leave_idea_convo(p_kind text, p_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from idea_convo_members where target_kind = p_kind and target_id = p_id and user_id = require_tester();
$$;

create or replace function public.post_idea_convo(p_kind text, p_id uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_author uuid;
  v_body text := btrim(regexp_replace(coalesce(p_body, ''), '\s+', ' ', 'g'));
  v_id uuid;
begin
  v_author := idea_target_author(p_kind, p_id, me);
  if not (in_idea_convo(p_kind, p_id, me) or v_author = me) then
    raise exception 'Join the conversation to comment.';
  end if;
  if (select status from profiles where id = me) is distinct from 'active' then raise exception 'Account not active'; end if;
  if char_length(v_body) < 1 then raise exception 'Say something first.'; end if;
  if char_length(v_body) > 500 then raise exception 'Keep it under 500 characters.'; end if;
  if blocked_term_in(v_body) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
  if cardinality(detect_contact(v_body)) > 0 then
    raise exception 'No contact info, links or handles here. Use "Let''s talk" to take it private.';
  end if;
  if (select count(*) from idea_convo_posts where author_id = me and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'That''s a lot of comments in an hour. Give people a chance to reply.';
  end if;
  insert into idea_convo_posts (target_kind, target_id, author_id, kind, body)
  values (p_kind, p_id, me, 'comment', v_body) returning id into v_id;
  perform notify_idea_convo(p_kind, p_id, me,
    (select display_name from profiles where id = me) || ' commented on "' || idea_target_title(p_kind, p_id) || '".');
  return v_id;
end $$;

-- Your own comment, or any comment on your own idea
create or replace function public.remove_idea_convo_post(p_post uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  c idea_convo_posts;
begin
  select * into c from idea_convo_posts where id = p_post;
  if c.id is null then return; end if;
  if c.author_id <> me and not (c.target_kind = 'idea' and (select author_id from ideas where id = c.target_id) = me) then
    raise exception 'You can only remove your own comments.';
  end if;
  update idea_convo_posts set removed = true where id = p_post;
end $$;

-- The thread itself, plus who's in it (members and the author only see the member list)
create or replace function public.get_idea_convo(p_kind text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_author uuid;
  v_joined boolean;
begin
  v_author := idea_target_author(p_kind, p_id, me);
  v_joined := coalesce(in_idea_convo(p_kind, p_id, me) or v_author = me, false);
  return jsonb_build_object(
    'joined', v_joined,
    'is_author', coalesce(v_author = me, false),
    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'author_id', c.author_id, 'name', u.display_name,
               'photo', (select ph.storage_path from photos ph where ph.user_id = c.author_id and ph.position = 1 and ph.review_status = 'approved'),
               'kind', c.kind, 'reason', reaction_label(c.reason), 'body', c.body, 'created_at', c.created_at,
               'mine', c.author_id = me, 'is_poster', c.author_id = v_author,
               'thread_id', case when v_author = me then
                              (select th.id from idea_threads th where th.idea_id = p_id and th.other_id = c.author_id) end)
             order by c.created_at)
      from idea_convo_posts c join profiles u on u.id = c.author_id and u.status = 'active'
      where c.target_kind = p_kind and c.target_id = p_id and not c.removed and not ideas_blocked(me, c.author_id)),
      '[]'::jsonb),
    'members', case when v_joined then coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', u.id, 'name', u.display_name, 'is_poster', u.id = v_author,
               'photo', (select ph.storage_path from photos ph where ph.user_id = u.id and ph.position = 1 and ph.review_status = 'approved'))
             order by u.id = v_author desc, x.joined_at)
      from (select m.user_id, m.joined_at from idea_convo_members m where m.target_kind = p_kind and m.target_id = p_id
            union all
            select v_author, null::timestamptz where v_author is not null
              and not exists (select 1 from idea_convo_members m2 where m2.target_kind = p_kind and m2.target_id = p_id and m2.user_id = v_author)) x
      join profiles u on u.id = x.user_id and u.status = 'active'
      where not ideas_blocked(me, u.id)), '[]'::jsonb) end);
end $$;

-- The author answers a push back or comment privately: opens (or reuses) a chat with that person
create or replace function public.idea_author_talk(p_idea uuid, p_user uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  i ideas;
  v_thread uuid;
begin
  select * into i from ideas where id = p_idea;
  if i.id is null or i.author_id <> me then raise exception 'That isn''t your idea.'; end if;
  if p_user = me then raise exception 'That''s you.'; end if;
  if ideas_blocked(me, p_user) or (select status from profiles where id = p_user) is distinct from 'active' then
    raise exception 'They aren''t available.';
  end if;
  if not exists (select 1 from idea_reactions r where r.target_kind = 'idea' and r.target_id = p_idea and r.user_id = p_user)
     and not exists (select 1 from idea_convo_posts c where c.target_kind = 'idea' and c.target_id = p_idea and c.author_id = p_user)
     and not exists (select 1 from idea_responses r where r.idea_id = p_idea and r.user_id = p_user) then
    raise exception 'They haven''t reacted to this idea.';
  end if;
  insert into idea_threads (idea_id, author_id, other_id) values (p_idea, me, p_user)
  on conflict (idea_id, other_id) do update set idea_id = excluded.idea_id
  returning id into v_thread;
  perform notify(p_user, 'idea_reply',
    (select display_name from profiles where id = me) || ' wants to talk about your take on their idea.');
  return v_thread;
end $$;

-- ---------------------------------------------------------------------
-- Routing: the feed now also follows backs (redefines get_ideas from 20261027000049; same shape)
--  * A friend tagged you ("I know someone")      -> it reaches you
--  * A friend backed it with a real reason       -> it reaches you
--  * Reason-weighted backs nudge it up a little for people it already fits (never to strangers)
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
           exists (select 1 from idea_responses r where r.idea_id = i.id and r.user_id = me) as responded,
           exists (select 1 from idea_reactions x where x.target_kind = 'idea' and x.target_id = i.id
                   and x.tagged_user = me) as tagged,
           exists (select 1 from idea_reactions x where x.target_kind = 'idea' and x.target_id = i.id
                   and x.reaction = 'back' and x.reason is not null and x.user_id <> me
                   and are_friends(me, x.user_id)) as friend_backed,
           least(idea_heat('idea', i.id), 12) as heat
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
           (b.is_mine or b.friend or b.responded or b.tagged or b.friend_backed
            or b.close_ov >= 2 or b.int_ov >= 1) as relevant,
           ( case when b.close_same then 6 else b.close_ov * 1.5 end
           + b.int_ov * 1.0
           + case when b.friend then 2.0 else 0 end
           + case when b.responded then 1.0 else 0 end
           + case when b.tagged then 4.0 else 0 end
           + case when b.friend_backed then 1.5 else 0 end
           + b.heat * 0.15
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
           when p.tagged then 'A friend thinks you''d be into this'
           when p.close_same then 'Close to an idea of yours'
           when p.friend then 'Your friend'
           when p.friend_backed then 'A friend backed this'
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
-- Idea -> group now invites the conversation too (redefines it from 20261027000049; same shape):
-- everyone who said "I'm in" and everyone who joined the conversation gets an invite.
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
    select x.user_id from (
      select ir.user_id, min(ir.created_at) as since from idea_responses ir
      where ir.idea_id = i.id and ir.kind = 'in' group by ir.user_id
      union all
      select m.user_id, min(m.joined_at) from idea_convo_members m
      where m.target_kind = 'idea' and m.target_id = i.id group by m.user_id
    ) x
    join profiles u on u.id = x.user_id and u.status = 'active'
    where x.user_id <> me and not ideas_blocked(me, x.user_id)
    group by x.user_id
    order by min(x.since)
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

-- invite_to_idea_group: conversation members count too (same shape)
create or replace function public.invite_to_idea_group(p_idea uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  i ideas;
begin
  select * into i from ideas where id = p_idea;
  if i.id is null or i.author_id <> me then raise exception 'That isn''t your idea.'; end if;
  if i.group_id is null then raise exception 'Start the group first.'; end if;
  if not exists (select 1 from idea_responses where idea_id = i.id and user_id = p_user)
     and not in_idea_convo('idea', i.id, p_user) then
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
-- Permissions: everything goes through functions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.react_to_idea(text,uuid,text,text,text,uuid)', 'public.my_backs_left()',
    'public.get_idea_reactions(text,uuid[])', 'public.join_idea_convo(text,uuid)',
    'public.leave_idea_convo(text,uuid)', 'public.post_idea_convo(text,uuid,text)',
    'public.remove_idea_convo_post(uuid)', 'public.get_idea_convo(text,uuid)',
    'public.idea_author_talk(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.backs_left(uuid)', 'public.idea_heat(text,uuid)', 'public.idea_target_author(text,uuid,uuid)', 'public.idea_target_title(text,uuid)',
    'public.in_idea_convo(text,uuid,uuid)', 'public.add_to_idea_convo(text,uuid,uuid)',
    'public.notify_idea_convo(text,uuid,uuid,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
