-- Idea cards (Nov 1 2026): short, saveable ideas from books, articles and thinkers, picked for each member,
-- whose real job is the same as the idea feed's: connecting people who think alike.
--  * Each card is a summary written in our own words, credited to its source. A short quote only from
--    public-domain works. Never copied passages.
--  * Labeled in the app: "Based pick", summary written by AI, kept separate from people's own posts.
--  * Up to 3 picked for you a day, matched to your interests, your ideas and the cards you've saved.
--    No counts anyone can see.
--  * Saving a card is how people find each other: someone who saved the same ideas you did shows up
--    under "Thinking alike". (Only people who saved the same card can see that you saved it.)
--  * A quiet nudge at most every 3 days when a card fits you well.
--  * Free: matching runs inside the database (word + interest overlap). Cards are loaded in batches
--    (admin_add_idea_cards); an AI writer can feed the same function later.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.idea_cards (
  id            uuid primary key default gen_random_uuid(),
  title         text not null check (char_length(title) between 3 and 90),
  body          text not null check (char_length(body) between 20 and 420),
  quote         text check (quote is null or char_length(quote) <= 160),
  source_title  text not null check (char_length(source_title) between 1 and 120),
  source_author text check (source_author is null or char_length(source_author) <= 80),
  source_url    text check (source_url is null or source_url ~ '^https://'),
  topics        text[] not null default '{}',   -- topic slugs (public.topics.slug)
  words         text[] not null default '{}',   -- word stems of title + body + topic names, for matching
  made_by       text not null default 'ai' check (made_by in ('ai','team')),
  status        text not null default 'live' check (status in ('live','hidden')),
  created_at    timestamptz not null default now(),
  unique (source_title, title)
);
create index if not exists idea_cards_words on public.idea_cards using gin (words);
create index if not exists idea_cards_topics on public.idea_cards using gin (topics);

create table if not exists public.card_saves (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  card_id    uuid not null references public.idea_cards(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, card_id)
);
create index if not exists card_saves_card on public.card_saves (card_id, created_at desc);

-- What each person has been shown (and on which day), so picks don't repeat; hidden = "not for me"
create table if not exists public.card_shown (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  card_id  uuid not null references public.idea_cards(id) on delete cascade,
  shown_on date not null default current_date,
  hidden   boolean not null default false,
  primary key (user_id, card_id)
);
create index if not exists card_shown_day on public.card_shown (user_id, shown_on);

-- "Not now" on a thinking-alike suggestion that came from shared saves
create table if not exists public.card_kindred_dismissals (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  other_id   uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, other_id)
);

alter table public.idea_cards              enable row level security;
alter table public.card_saves              enable row level security;
alter table public.card_shown              enable row level security;
alter table public.card_kindred_dismissals enable row level security;

-- ---------------------------------------------------------------------
-- Loading cards (admin, or a future AI writer through the same path)
-- ---------------------------------------------------------------------
-- p_cards: [{"title","body","quote"?,"source_title","source_author"?,"source_url"?,"topics":[slugs]}]
create or replace function public.put_idea_cards(p_cards jsonb, p_made_by text default 'ai')
returns int language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
  v_topics text[];
  n int := 0;
begin
  for c in select * from jsonb_array_elements(coalesce(p_cards, '[]'::jsonb)) loop
    select coalesce(array_agg(t.slug), '{}') into v_topics
    from topics t where t.slug in (select jsonb_array_elements_text(coalesce(c->'topics', '[]'::jsonb)));

    insert into idea_cards (title, body, quote, source_title, source_author, source_url, topics, words, made_by)
    values (btrim(c->>'title'), btrim(c->>'body'), nullif(btrim(coalesce(c->>'quote', '')), ''),
            btrim(c->>'source_title'), nullif(btrim(coalesce(c->>'source_author', '')), ''),
            nullif(btrim(coalesce(c->>'source_url', '')), ''), v_topics,
            idea_words(concat_ws(' ', c->>'title', c->>'body',
                                 (select string_agg(t.name, ' ') from topics t where t.slug = any (v_topics)))),
            p_made_by)
    on conflict (source_title, title) do update
       set body = excluded.body, quote = excluded.quote, source_author = excluded.source_author,
           source_url = excluded.source_url, topics = excluded.topics, words = excluded.words;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.admin_add_idea_cards(p_cards jsonb)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  return put_idea_cards(p_cards, 'ai');
end $$;

create or replace function public.admin_set_card_status(p_card uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  if p_status not in ('live','hidden') then raise exception 'Bad status'; end if;
  update idea_cards set status = p_status where id = p_card;
end $$;

-- ---------------------------------------------------------------------
-- Matching: how well a card fits a person
-- ---------------------------------------------------------------------
-- A person's "fingerprint": their interest slugs, and the word stems of their interests,
-- their recent ideas and the cards they've saved.
create or replace function public.card_fingerprint(p_user uuid, out slugs text[], out words text[])
language sql stable security definer set search_path = public as $$
  select
    (select coalesce(array_agg(t.slug), '{}') from user_topics ut join topics t on t.id = ut.topic_id
      where ut.user_id = p_user),
    (select coalesce(array_agg(distinct w), '{}') from (
       select unnest(idea_words(t.name)) w from user_topics ut join topics t on t.id = ut.topic_id where ut.user_id = p_user
       union all
       select unnest(i.words) from ideas i
        where i.author_id = p_user and i.status <> 'removed' and i.created_at > now() - interval '90 days'
       union all
       select unnest(c.words) from card_saves s join idea_cards c on c.id = s.card_id where s.user_id = p_user
     ) x);
$$;

-- interests count most, then word overlap with what you've posted and saved
create or replace function public.card_score(c public.idea_cards, p_slugs text[], p_words text[])
returns numeric language sql immutable as $$
  select cardinality(array(select unnest(c.topics) intersect select unnest(p_slugs))) * 3.0
       + least(word_overlap(c.words, p_words), 4) * 1.0;
$$;

-- ---------------------------------------------------------------------
-- Today's picks (up to 3; the same ones all day)
-- ---------------------------------------------------------------------
create or replace function public.get_idea_cards()
returns table (card_id uuid, title text, body text, quote text, source_title text, source_author text,
               source_url text, made_by text, why text, saved boolean)
language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  fp record;
  have int;
begin
  if (select status from profiles where id = me) is distinct from 'active' then return; end if;
  select * into fp from card_fingerprint(me);

  select count(*) into have from card_shown where user_id = me and shown_on = current_date;
  if have < 3 then
    insert into card_shown (user_id, card_id, shown_on)
    select me, c.id, current_date
    from idea_cards c
    where c.status = 'live'
      and not exists (select 1 from card_shown s where s.user_id = me and s.card_id = c.id)
    order by card_score(c, fp.slugs, fp.words) desc, random()
    limit 3 - have
    on conflict do nothing;
  end if;

  return query
  select c.id, c.title, c.body, c.quote, c.source_title, c.source_author, c.source_url, c.made_by,
         coalesce('Fits ' || (select string_agg(t.name, ', ' order by t.name) from topics t
                               where t.slug = any (c.topics) and t.slug = any (fp.slugs)),
                  case when word_overlap(c.words, fp.words) >= 1 then 'Close to what you post and save'
                       else 'Something new to try' end),
         exists (select 1 from card_saves v where v.user_id = me and v.card_id = c.id)
  from card_shown s join idea_cards c on c.id = s.card_id
  where s.user_id = me and s.shown_on = current_date and not s.hidden and c.status = 'live'
  order by card_score(c, fp.slugs, fp.words) desc, c.created_at;
end $$;

create or replace function public.save_idea_card(p_card uuid, p_save boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if p_save then
    if not exists (select 1 from idea_cards where id = p_card and status = 'live') then raise exception 'That card is gone.'; end if;
    insert into card_saves (user_id, card_id) values (me, p_card) on conflict do nothing;
  else
    delete from card_saves where user_id = me and card_id = p_card;
  end if;
end $$;

create or replace function public.hide_idea_card(p_card uuid)
returns void language sql security definer set search_path = public as $$
  insert into card_shown (user_id, card_id, hidden) values (require_tester(), p_card, true)
  on conflict (user_id, card_id) do update set hidden = true;
$$;

create or replace function public.get_saved_cards()
returns table (card_id uuid, title text, body text, quote text, source_title text, source_author text,
               source_url text, made_by text, saved_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.title, c.body, c.quote, c.source_title, c.source_author, c.source_url, c.made_by, s.created_at
  from card_saves s join idea_cards c on c.id = s.card_id
  where s.user_id = require_tester() and c.status = 'live'
  order by s.created_at desc;
$$;

-- ---------------------------------------------------------------------
-- Thinking alike: people who saved the same ideas you did
-- ---------------------------------------------------------------------
create or replace function public.get_card_kindred()
returns table (user_id uuid, name text, photo text, shared int, card_title text)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if effective_tier(me) = 'invisible' then return; end if;
  return query
  select o.user_id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = o.user_id and ph.position = 1 and ph.review_status = 'approved'),
         count(*)::int,
         (array_agg(c.title order by o.created_at desc))[1]
  from card_saves m
  join card_saves o on o.card_id = m.card_id and o.user_id <> me
  join idea_cards c on c.id = m.card_id and c.status = 'live'
  join profiles p on p.id = o.user_id and p.status = 'active'
  where m.user_id = me
    and o.created_at > now() - interval '120 days'
    and effective_tier(o.user_id) <> 'invisible'
    and not ideas_blocked(me, o.user_id)
    and not are_friends(me, o.user_id)
    and not exists (select 1 from card_kindred_dismissals d where d.user_id = me and d.other_id = o.user_id)
  group by o.user_id, p.display_name
  order by count(*) desc, max(o.created_at) desc
  limit 5;
end $$;

create or replace function public.dismiss_card_kindred(p_user uuid)
returns void language sql security definer set search_path = public as $$
  insert into card_kindred_dismissals (user_id, other_id) values (require_tester(), p_user) on conflict do nothing;
$$;

-- ---------------------------------------------------------------------
-- Daily nudge: when an unseen card fits someone well (interest + words), at most every 3 days
-- ---------------------------------------------------------------------
create or replace function public.nudge_idea_cards()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  fp record;
  v_card uuid;
  v_title text;
  n int := 0;
begin
  for r in
    select p.id from profiles p
    where p.status = 'active' and is_tester(p.id)
      and exists (select 1 from user_topics ut where ut.user_id = p.id)
      and not exists (select 1 from notifications x where x.user_id = p.id and x.kind = 'idea_card'
                        and x.created_at > now() - interval '3 days')
      and (select count(*) from card_shown s where s.user_id = p.id and s.shown_on = current_date) < 3
  loop
    select * into fp from card_fingerprint(r.id);
    v_title := null;
    select c.id, c.title into v_card, v_title
    from idea_cards c
    where c.status = 'live'
      and not exists (select 1 from card_shown s where s.user_id = r.id and s.card_id = c.id)
      and not exists (select 1 from card_saves v where v.user_id = r.id and v.card_id = c.id)
      and card_score(c, fp.slugs, fp.words) >= 4
    order by card_score(c, fp.slugs, fp.words) desc, random()
    limit 1;
    if v_title is not null then
      -- it becomes one of today's picks, so it's waiting in Ideas when they open the app
      insert into card_shown (user_id, card_id, shown_on) values (r.id, v_card, current_date) on conflict do nothing;
      perform notify(r.id, 'idea_card', 'An idea picked for you: "' || v_title || '". It''s in Ideas.');
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'nudge-idea-cards') then
    perform cron.unschedule('nudge-idea-cards');
  end if;
  perform cron.schedule('nudge-idea-cards', '13 16 * * *', 'select public.nudge_idea_cards()');  -- ~9-10 am Calgary
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_idea_cards()', 'public.save_idea_card(uuid,boolean)', 'public.hide_idea_card(uuid)',
    'public.get_saved_cards()', 'public.get_card_kindred()', 'public.dismiss_card_kindred(uuid)',
    'public.admin_add_idea_cards(jsonb)', 'public.admin_set_card_status(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.put_idea_cards(jsonb,text)', 'public.card_fingerprint(uuid)',
    'public.nudge_idea_cards()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
