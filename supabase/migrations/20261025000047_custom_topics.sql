-- Custom post topics + more tech / business / giving-back / philosophy topics (Oct 25 2026).
--  * In New post, members can make their own topic if the list doesn't have it.
--  * Safety filter on the name: 2-30 characters, letters/numbers/basic punctuation only,
--    no contact info or links, and no profanity, slurs, sexual, drug or violent terms
--    (checked after undoing leetspeak and spacing tricks, e.g. "s.3.x" or "f u c k").
--  * Same name as an existing topic (any case) just uses that topic.
--  * 3 new topics per person per day.
--  * Custom topics show in the post topic list for everyone, not in the interest picker.
--  * The owner can hide a custom topic (The door → Custom topics); its posts come off the feed.
-- Safe to re-run.

-- ---------- more official topics ----------
insert into public.topics (slug, name) values
 -- tech
 ('ai','AI'),('software','Software & coding'),('startups','Startups'),('cybersecurity','Cybersecurity'),
 ('crypto','Crypto & Web3'),('gadgets','Gadgets'),('data','Data & analytics'),('robotics','Robotics'),
 ('space','Space'),('product-design','Product & design'),('evs','Electric vehicles'),('energy-tech','Energy tech'),
 -- business
 ('entrepreneurship','Entrepreneurship'),('small-business','Small business'),('real-estate','Real estate'),
 ('marketing','Marketing'),('sales','Sales'),('leadership','Leadership'),('personal-finance','Personal finance'),
 ('stock-market','Stock market'),('side-hustles','Side hustles'),('venture-capital','Venture capital'),
 ('agriculture','Agriculture & ranching'),('oil-gas','Oil & gas'),('networking','Networking'),('careers','Careers'),
 -- philanthropy / giving back
 ('philanthropy','Philanthropy'),('volunteering','Volunteering'),('fundraising','Charity & fundraising'),
 ('community','Community building'),('mentorship','Mentorship'),('nonprofits','Nonprofits'),
 ('conservation','Environment & conservation'),('animal-rescue','Animal rescue'),('coaching-youth','Youth sports & coaching'),
 -- philosophy
 ('philosophy','Philosophy'),('stoicism','Stoicism'),('ethics','Ethics'),('meaning','Meaning & purpose'),
 ('mind','Philosophy of mind'),('free-will','Free will'),('existentialism','Existentialism'),
 ('political-philosophy','Political philosophy'),('logic','Logic & reasoning'),('eastern-philosophy','Eastern philosophy'),
 ('great-books','Great books & thinkers'),('big-questions','Big questions')
on conflict (slug) do nothing;

alter table public.topics add column if not exists custom boolean not null default false;
alter table public.topics add column if not exists created_by uuid references public.profiles(id) on delete set null;
alter table public.topics add column if not exists created_at timestamptz not null default now();
alter table public.topics add column if not exists hidden boolean not null default false;
create unique index if not exists topics_name_ci on public.topics (lower(name));

-- ---------- the filter ----------
create table if not exists public.blocked_terms (
  term  text primary key,   -- lowercase, letters only
  whole boolean not null default false   -- true: only as a whole word (short terms that hide inside normal words)
);
alter table public.blocked_terms enable row level security;   -- functions only

insert into public.blocked_terms (term, whole) values
 -- profanity
 ('fuck',false),('fuk',true),('fck',true),('shit',false),('bitch',false),('cunt',true),('cunts',true),('asshole',false),
 ('bastard',false),('dick',true),('dicks',true),('cock',true),('cocks',true),('pussy',false),('twat',true),
 ('wank',false),('bollocks',false),('motherf',false),('slut',false),('whore',false),('hoe',true),('hoes',true),
 ('ass',true),('arse',true),('damn',true),('piss',true),('prick',true),('douche',false),('jackass',false),
-- slurs and hate
 ('nigg',false),('nigga',false),('negro',false),('chink',false),('spic',true),('spick',true),('kike',false),
 ('wetback',false),('gook',false),('raghead',false),('towelhead',false),('beaner',false),('coon',true),
 ('paki',true),('faggot',false),('fag',true),('fags',true),('dyke',true),('tranny',false),('retard',false),
 ('nazi',false),('hitler',false),('kkk',true),('whitepower',false),('heilhitler',false),('siegheil',false),
 ('jihad',false),('isis',true),('genocide',false),('supremac',false),('eugenic',false),
 -- sexual
 ('sex',true),('sexy',true),('sexting',false),('porn',false),('nude',false),('nudes',false),('naked',false),
 ('nsfw',false),('pron',true),('onlyfans',false),('hookup',false),('hookups',false),('fwb',true),('escorts',true),('hooker',false),
 ('milf',false),('dilf',false),('horny',false),('kink',false),('fetish',false),('bdsm',false),('orgy',false),
 ('threesome',false),('blowjob',false),('handjob',false),('anal',true),('cum',true),('cumming',false),
 ('boobs',false),('tits',true),('titties',false),('penis',false),('vagina',false),('dildo',false),('erotic',false),
 ('xxx',true),('camgirl',false),('sugardaddy',false),('sugarbaby',false),('pedo',false),('paedo',false),
 ('loli',true),('incest',false),('rape',true),('raped',true),('rapist',true),('rapists',true),('upskirt',false),('jailbait',false),
 -- drugs
 ('cocaine',false),('coke',true),('meth',true),('crystalmeth',false),('heroin',false),('fentanyl',false),
 ('mdma',false),('ecstasy',false),('ketamine',false),('lsd',true),('shrooms',true),
 ('xanax',false),('percs',true),('crackhead',false),('drugdeal',false),
 -- violence / harm
 ('kill',true),('killing',true),('murdering',false),('massshooting',false),('bombmaking',false),('pipebomb',false),
 ('terror',false),('massacre',false),('suicide',false),('selfharm',false),('kys',true),('lynch',false),
 ('behead',false),('torture',false),('gore',true),('schoolshoot',false),
 -- scams / spam
 ('getrichquick',false),('cashapp',false),('venmo',true),('giveaway',false),('freemoney',false),('forex',true),
 ('pumpanddump',false)
on conflict (term) do nothing;

-- lowercase, undo leetspeak, keep letters and spaces
create or replace function public.normalize_for_filter(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(
           translate(lower(coalesce(p, '')), '013457@$!|+', 'oieastasiit'),
           '[^a-z ]', '', 'g'), '\s+', ' ', 'g'));
$$;

-- Returns the first blocked term found, or null if the text is clean
create or replace function public.blocked_term_in(p text)
returns text language sql stable security definer set search_path = public as $$
  with n as (select normalize_for_filter(p) as t),
       w as (select regexp_split_to_table((select t from n), ' ') as word),
       squashed as (select replace((select t from n), ' ', '') as s),
       -- "f u c k": also join runs of single letters
       joined as (select string_agg(word, '') as j from w where char_length(word) = 1)
  select b.term from blocked_terms b
  where (b.whole and (exists (select 1 from w where w.word = b.term)
                      or (select s from squashed) = b.term
                      or coalesce((select j from joined), '') = b.term))
     or (not b.whole and (exists (select 1 from w where w.word like '%' || b.term || '%')
                          or coalesce((select j from joined), '') like '%' || b.term || '%'
                          or (char_length(b.term) >= 6 and (select s from squashed) like '%' || b.term || '%')))
  limit 1;
$$;

-- ---------- make a topic ----------
create or replace function public.create_topic(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  t topics;
  v_slug text;
begin
  if me is null or not exists (select 1 from profiles where id = me and status in ('active','paused','onboarding')) then
    raise exception 'Sign in to make a topic.';
  end if;
  if char_length(v) < 2 or char_length(v) > 30 then raise exception 'Topic names are 2 to 30 characters.'; end if;
  if v !~ '^[A-Za-z0-9][A-Za-z0-9 &''.,+/-]*$' then
    raise exception 'Use letters, numbers and simple punctuation only.';
  end if;
  if v !~ '[A-Za-z]{2}' then raise exception 'Give it a real name.'; end if;

  -- already exists? use it
  select * into t from topics where lower(name) = lower(v);
  if t.id is not null then
    if t.hidden then raise exception 'That topic isn''t available.'; end if;
    return jsonb_build_object('id', t.id, 'name', t.name, 'existing', true);
  end if;

  if detect_contact(v) <> '{}'::text[] then raise exception 'Topic names can''t have contact info or links.'; end if;
  if blocked_term_in(v) is not null then raise exception 'That topic name isn''t allowed. Keep it clean.'; end if;
  if (select count(*) from topics where created_by = me and created_at > now() - interval '1 day') >= 3 then
    raise exception 'That''s 3 new topics today. Try again tomorrow.';
  end if;

  -- capitalize the first letter only, keep the rest as typed ("AI ethics", "Craft beer")
  v := upper(left(v, 1)) || substr(v, 2);
  v_slug := 'u-' || left(regexp_replace(lower(v), '[^a-z0-9]+', '-', 'g'), 40) || '-' || substr(md5(random()::text), 1, 5);
  insert into topics (slug, name, custom, created_by) values (v_slug, v, true, me) returning * into t;
  return jsonb_build_object('id', t.id, 'name', t.name, 'existing', false);
end $$;

-- Topics for the New post list: official + live custom ones
create or replace function public.post_topics()
returns table (id int, name text, custom boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.name, t.custom from topics t where not t.hidden
  order by t.custom, t.name;
$$;

-- No posting into a hidden topic
create or replace function public.tg_post_topic_live()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select hidden from topics where id = new.topic_id) then
    raise exception 'That topic isn''t available.';
  end if;
  return new;
end $$;
drop trigger if exists post_topic_live on public.posts;
create trigger post_topic_live before insert on public.posts
  for each row execute function public.tg_post_topic_live();

-- ---------- owner ----------
create or replace function public.admin_custom_topics()
returns table (id int, name text, made_by text, created_at timestamptz, posts int, hidden boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select t.id, t.name, p.display_name, t.created_at,
         (select count(*)::int from posts x where x.topic_id = t.id), t.hidden
  from topics t left join profiles p on p.id = t.created_by
  where t.custom order by t.created_at desc limit 200;
end $$;

create or replace function public.admin_hide_topic(p_topic int, p_hidden boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  if not (select custom from topics where id = p_topic) then raise exception 'Only custom topics can be hidden.'; end if;
  update topics set hidden = coalesce(p_hidden, true) where id = p_topic;
  if coalesce(p_hidden, true) then
    update posts set status = 'removed' where topic_id = p_topic and status = 'visible';
  end if;
end $$;

-- Interest pickers keep showing official topics only (custom ones are for posts)
drop policy if exists "topics read" on public.topics;
create policy "topics read" on public.topics for select to authenticated using (not hidden);

do $$
declare f text;
begin
  foreach f in array array['public.create_topic(text)', 'public.post_topics()',
                           'public.admin_custom_topics()', 'public.admin_hide_topic(int,boolean)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke all on function public.blocked_term_in(text) from public, anon, authenticated;
end $$;
