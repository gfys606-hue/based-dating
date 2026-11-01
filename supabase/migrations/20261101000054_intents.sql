-- Intents (Nov 1 2026, from the Oct 27 vision doc): what you're up for, right now.
--  * Looking for (right now): gym partner, fishing partner, co-founder, investor, developer, buy, sell…
--    Each one lasts 2 weeks unless renewed, so the list stays current.
--  * I'm available for: dating, gym, fishing, camping, entrepreneurship, local events…
--  * I can / I need: skills and resources, matched both ways ("I have an idea and money, need a builder"
--    finds "I can build apps, looking for a start-up").
--  * Matches are people in your city whose intents fit yours, each with the plain-English reason.
--    No counts, no ranking anyone can see. Blocked and hidden people never show.
--  * When you add something new, up to 3 of the best-fitting people get a quiet nudge
--    (each person at most once every 3 days).
--  * Dating stays in Ouch (gender and who you're seeking apply there); here "Dating" is only shown, never matched.
--  * Everything comes from fixed lists (plus a short optional note on I can / I need), so nothing needs moderating.
-- Safe to re-run.

-- ---------------------------------------------------------------------
-- The options (one place; the app reads them from intent_options())
-- ---------------------------------------------------------------------
create or replace function public.intent_options()
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'looking', jsonb_build_array(
      jsonb_build_object('tag','gym-partner','label','Gym partner'),
      jsonb_build_object('tag','running-partner','label','Running partner'),
      jsonb_build_object('tag','hiking-partner','label','Hiking partner'),
      jsonb_build_object('tag','fishing-partner','label','Fishing partner'),
      jsonb_build_object('tag','hunting-partner','label','Hunting partner'),
      jsonb_build_object('tag','camping-crew','label','Camping crew'),
      jsonb_build_object('tag','golf-partner','label','Golf partner'),
      jsonb_build_object('tag','gaming-group','label','Gaming group'),
      jsonb_build_object('tag','travel-buddy','label','Travel buddy'),
      jsonb_build_object('tag','new-friends','label','New friends'),
      jsonb_build_object('tag','cofounder','label','Co-founder or business partner'),
      jsonb_build_object('tag','developer','label','Developer'),
      jsonb_build_object('tag','designer','label','Designer'),
      jsonb_build_object('tag','investor','label','Investor'),
      jsonb_build_object('tag','mentor','label','Mentor'),
      jsonb_build_object('tag','mentee','label','Someone to mentor'),
      jsonb_build_object('tag','employees','label','People to hire'),
      jsonb_build_object('tag','work','label','Work or a job'),
      jsonb_build_object('tag','contractor','label','Contractor or tradesperson'),
      jsonb_build_object('tag','buy','label','To buy something'),
      jsonb_build_object('tag','sell','label','To sell something')),
    'available', jsonb_build_array(
      jsonb_build_object('tag','dating','label','Dating'),
      jsonb_build_object('tag','friends','label','Friends'),
      jsonb_build_object('tag','drinks','label','Drinks and nights out'),
      jsonb_build_object('tag','gym','label','Gym'),
      jsonb_build_object('tag','running','label','Running'),
      jsonb_build_object('tag','hiking','label','Hiking'),
      jsonb_build_object('tag','fishing','label','Fishing'),
      jsonb_build_object('tag','hunting','label','Hunting'),
      jsonb_build_object('tag','camping','label','Camping'),
      jsonb_build_object('tag','golf','label','Golf'),
      jsonb_build_object('tag','gaming','label','Gaming'),
      jsonb_build_object('tag','sports','label','Sports'),
      jsonb_build_object('tag','travel','label','Travel'),
      jsonb_build_object('tag','entrepreneurship','label','Entrepreneurship'),
      jsonb_build_object('tag','mentoring','label','Mentoring'),
      jsonb_build_object('tag','volunteering','label','Volunteering'),
      jsonb_build_object('tag','local-events','label','Local events')),
    'skills', jsonb_build_array(
      jsonb_build_object('tag','build-apps','label','Building apps and software'),
      jsonb_build_object('tag','design','label','Design'),
      jsonb_build_object('tag','marketing','label','Marketing'),
      jsonb_build_object('tag','sales','label','Sales'),
      jsonb_build_object('tag','funding','label','Money to invest'),
      jsonb_build_object('tag','idea','label','A business idea'),
      jsonb_build_object('tag','management','label','Running a business'),
      jsonb_build_object('tag','trades','label','Trades and building'),
      jsonb_build_object('tag','welding','label','Welding'),
      jsonb_build_object('tag','mechanic','label','Mechanical work'),
      jsonb_build_object('tag','legal','label','Legal know-how'),
      jsonb_build_object('tag','accounting','label','Accounting and finance'),
      jsonb_build_object('tag','photo-video','label','Photo and video'),
      jsonb_build_object('tag','writing','label','Writing'),
      jsonb_build_object('tag','coaching','label','Coaching and training'),
      jsonb_build_object('tag','equipment','label','Equipment, truck or trailer'),
      jsonb_build_object('tag','space','label','Space or a location'),
      jsonb_build_object('tag','connections','label','Connections and intros'),
      jsonb_build_object('tag','hands','label','An extra pair of hands'))
  );
$$;

create or replace function public.intent_label(p_kind text, p_tag text)
returns text language sql immutable as $$
  select e->>'label'
  from jsonb_array_elements(intent_options() -> (case when p_kind in ('can','need') then 'skills' else p_kind end)) e
  where e->>'tag' = p_tag;
$$;

-- ---------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------
create table if not exists public.profile_intents (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('looking','available','can','need')),
  tag        text not null,
  note       text check (note is null or char_length(note) between 1 and 120),
  expires_at timestamptz,            -- 'looking' only: 2 weeks, renewable
  created_at timestamptz not null default now(),
  primary key (user_id, kind, tag)
);
create index if not exists profile_intents_tag on public.profile_intents (kind, tag);
alter table public.profile_intents enable row level security;

-- Pairs that fit each other: a's item -> b's item. `reason` is why b fits a; `reason_back` is why a fits b
-- (null when the pair is listed both ways). {label} = the skill's label (I need / I can).
create or replace function public.intent_pairs()
returns table (a_kind text, a_tag text, b_kind text, b_tag text, reason text, reason_back text)
language sql immutable as $$
  values
    -- the same partner wanted on both sides
    ('looking','gym-partner','looking','gym-partner','You''re both looking for a gym partner',null),
    ('looking','running-partner','looking','running-partner','You''re both looking for a running partner',null),
    ('looking','hiking-partner','looking','hiking-partner','You''re both looking for a hiking partner',null),
    ('looking','fishing-partner','looking','fishing-partner','You''re both looking for a fishing partner',null),
    ('looking','hunting-partner','looking','hunting-partner','You''re both looking for a hunting partner',null),
    ('looking','camping-crew','looking','camping-crew','You''re both putting a camping crew together',null),
    ('looking','golf-partner','looking','golf-partner','You''re both looking for a golf partner',null),
    ('looking','gaming-group','looking','gaming-group','You''re both looking for a gaming group',null),
    ('looking','travel-buddy','looking','travel-buddy','You''re both looking for a travel buddy',null),
    ('looking','new-friends','looking','new-friends','You''re both looking for new friends',null),
    ('looking','cofounder','looking','cofounder','You''re both looking for a co-founder',null),
    -- looking for a partner <-> up for that activity
    ('looking','gym-partner','available','gym','Up for the gym','Looking for a gym partner'),
    ('looking','running-partner','available','running','Up for running','Looking for a running partner'),
    ('looking','hiking-partner','available','hiking','Up for hiking','Looking for a hiking partner'),
    ('looking','fishing-partner','available','fishing','Up for fishing','Looking for a fishing partner'),
    ('looking','hunting-partner','available','hunting','Up for hunting','Looking for a hunting partner'),
    ('looking','camping-crew','available','camping','Up for camping','Putting a camping crew together'),
    ('looking','golf-partner','available','golf','Up for golf','Looking for a golf partner'),
    ('looking','gaming-group','available','gaming','Up for gaming','Looking for a gaming group'),
    ('looking','travel-buddy','available','travel','Up for travel','Looking for a travel buddy'),
    ('looking','new-friends','available','friends','Open to new friends','Looking for new friends'),
    ('looking','cofounder','available','entrepreneurship','Into entrepreneurship','Looking for a co-founder'),
    ('looking','mentor','available','mentoring','Open to mentoring','Looking for a mentor'),
    -- looking for a person <-> what they can do
    ('looking','developer','can','build-apps','Can help with {label}','Looking for a developer'),
    ('looking','designer','can','design','Can help with {label}','Looking for a designer'),
    ('looking','investor','can','funding','Has money to invest','Looking for an investor'),
    ('looking','mentor','can','coaching','Can coach','Looking for a mentor'),
    ('looking','contractor','can','trades','Can help with {label}','Looking for a contractor'),
    ('looking','contractor','can','welding','Can help with {label}','Looking for a contractor'),
    ('looking','contractor','can','mechanic','Can help with {label}','Looking for a contractor'),
    ('looking','cofounder','can','idea','Has a business idea','Looking for a co-founder'),
    ('looking','cofounder','can','management','Can run a business','Looking for a co-founder'),
    -- two sides of the same deal
    ('looking','employees','looking','work','Looking for work','Hiring'),
    ('looking','mentee','looking','mentor','Looking for a mentor','Wants someone to mentor'),
    ('looking','buy','looking','sell','Selling something',null),
    ('looking','sell','looking','buy','Looking to buy',null),
    -- what you need <-> what they can do
    ('need','*','can','*','Can help with {label}','Needs help with {label}')
$$;

-- Every reason b fits a, in plain English
create or replace function public.intent_fits(p_a uuid, p_b uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct x.reason), '{}')
  from (
    -- a's item matches b's item
    select replace(pr.reason, '{label}', lower(intent_label(bi.kind, bi.tag))) as reason
    from profile_intents ai
    join intent_pairs() pr on pr.a_kind = ai.kind and (pr.a_tag = ai.tag or pr.a_tag = '*')
    join profile_intents bi on bi.user_id = p_b and bi.kind = pr.b_kind
                           and (pr.b_tag = bi.tag or (pr.b_tag = '*' and bi.tag = ai.tag))
    where ai.user_id = p_a
      and (ai.expires_at is null or ai.expires_at > now())
      and (bi.expires_at is null or bi.expires_at > now())
    union all
    -- b's item matches a's item (read backwards)
    select replace(pr.reason_back, '{label}', lower(intent_label(ai.kind, ai.tag)))
    from profile_intents ai
    join intent_pairs() pr on pr.reason_back is not null and pr.b_kind = ai.kind and (pr.b_tag = ai.tag or pr.b_tag = '*')
    join profile_intents bi on bi.user_id = p_b and bi.kind = pr.a_kind
                           and (pr.a_tag = bi.tag or (pr.a_tag = '*' and bi.tag = ai.tag))
    where ai.user_id = p_a
      and (ai.expires_at is null or ai.expires_at > now())
      and (bi.expires_at is null or bi.expires_at > now())
  ) x
  where x.reason is not null;
$$;

-- ---------------------------------------------------------------------
-- Your own intents
-- ---------------------------------------------------------------------
create or replace function public.get_intent_options()
returns jsonb language sql stable security definer set search_path = public as $$
  select intent_options();
$$;

create or replace function public.get_my_intents()
returns table (kind text, tag text, label text, note text, expires_at timestamptz)
language sql stable security definer set search_path = public as $$
  select i.kind, i.tag, intent_label(i.kind, i.tag), i.note, i.expires_at
  from profile_intents i
  where i.user_id = require_tester()
    and (i.expires_at is null or i.expires_at > now())
  order by i.kind, i.created_at;
$$;

-- p_items: [{"kind":"looking","tag":"gym-partner"}, {"kind":"need","tag":"build-apps","note":"for a welding booking app"}, …]
-- Replaces your whole list. Up to 6 per kind. Looking-for items keep their clock unless new (then 2 weeks).
create or replace function public.set_my_intents(p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  e jsonb;
  v_kind text;
  v_tag text;
  v_note text;
  v_clean jsonb := '[]'::jsonb;
  v_new int := 0;
begin
  if (select status from profiles where id = me) is distinct from 'active' then
    raise exception 'Finish setting up your profile first.';
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_kind := e->>'kind';
    v_tag := e->>'tag';
    v_note := nullif(btrim(regexp_replace(coalesce(e->>'note', ''), '\s+', ' ', 'g')), '');
    if v_kind is null or v_kind not in ('looking','available','can','need') or intent_label(v_kind, v_tag) is null then
      raise exception 'That option isn''t on the list.';
    end if;
    if v_kind not in ('can','need') then v_note := null; end if;
    if v_note is not null then
      v_note := left(v_note, 120);
      if blocked_term_in(v_note) is not null then raise exception 'Keep it clean: that wording isn''t allowed.'; end if;
      if cardinality(detect_contact(v_note)) > 0 then
        raise exception 'Notes can''t include contact info, links or handles. People reach you here.';
      end if;
    end if;
    v_clean := v_clean || jsonb_build_array(jsonb_build_object('kind', v_kind, 'tag', v_tag, 'note', v_note));
  end loop;

  if exists (select 1 from jsonb_to_recordset(v_clean) n(kind text, tag text, note text)
             group by n.kind having count(distinct n.tag) > 6) then
    raise exception 'Pick up to 6 in each list.';
  end if;

  delete from profile_intents i
  where i.user_id = me
    and not exists (select 1 from jsonb_to_recordset(v_clean) n(kind text, tag text, note text)
                    where n.kind = i.kind and n.tag = i.tag);

  select count(*) into v_new from jsonb_to_recordset(v_clean) n(kind text, tag text, note text)
  where not exists (select 1 from profile_intents i where i.user_id = me and i.kind = n.kind and i.tag = n.tag
                    and (i.expires_at is null or i.expires_at > now()));

  insert into profile_intents (user_id, kind, tag, note, expires_at)
  select distinct on (n.kind, n.tag) me, n.kind, n.tag, n.note,
         case when n.kind = 'looking' then now() + interval '14 days' end
  from jsonb_to_recordset(v_clean) n(kind text, tag text, note text)
  on conflict (user_id, kind, tag) do update
     set note = excluded.note,
         -- an expired looking-for that's picked again starts a fresh 2 weeks
         expires_at = case when profile_intents.kind <> 'looking' then null
                           when profile_intents.expires_at is null or profile_intents.expires_at <= now()
                             then excluded.expires_at
                           else profile_intents.expires_at end,
         created_at = case when profile_intents.expires_at is not null and profile_intents.expires_at <= now()
                           then now() else profile_intents.created_at end;

  if v_new > 0 then perform nudge_intent_matches(me); end if;
end $$;

-- Keep a looking-for going another 2 weeks
create or replace function public.renew_intent(p_tag text)
returns void language sql security definer set search_path = public as $$
  update profile_intents set expires_at = now() + interval '14 days'
  where user_id = require_tester() and kind = 'looking' and tag = p_tag;
$$;

-- ---------------------------------------------------------------------
-- Someone else's intents (on their profile)
-- ---------------------------------------------------------------------
create or replace function public.get_user_intents(p_user uuid)
returns table (kind text, tag text, label text, note text, fits boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
begin
  if p_user <> me and (ideas_blocked(me, p_user) or effective_tier(p_user) = 'invisible') then return; end if;
  return query
  select i.kind, i.tag, intent_label(i.kind, i.tag), i.note,
         -- true when this item is part of why you two fit
         p_user <> me and exists (
           select 1 from profile_intents mi
           join intent_pairs() pr on (pr.a_kind = mi.kind and (pr.a_tag = mi.tag or pr.a_tag = '*')
                                       and pr.b_kind = i.kind and (pr.b_tag = i.tag or (pr.b_tag = '*' and i.tag = mi.tag)))
                                  or (pr.b_kind = mi.kind and (pr.b_tag = mi.tag or pr.b_tag = '*')
                                       and pr.a_kind = i.kind and (pr.a_tag = i.tag or (pr.a_tag = '*' and i.tag = mi.tag)))
           where mi.user_id = me and (mi.expires_at is null or mi.expires_at > now()))
  from profile_intents i
  where i.user_id = p_user and (i.expires_at is null or i.expires_at > now())
  order by array_position(array['looking','available','can','need'], i.kind), i.created_at;
end $$;

-- ---------------------------------------------------------------------
-- Matches: people in your city whose intents fit yours
-- ---------------------------------------------------------------------
create or replace function public.get_intent_matches(p_limit int default 30)
returns table (user_id uuid, name text, age int, photo text, reasons text[], is_friend boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
begin
  select * into v from profiles where id = me;
  if effective_tier(me) = 'invisible' then return; end if;
  return query
  select x.id, x.display_name, extract(year from age(x.birthdate))::int,
         (select ph.storage_path from photos ph where ph.user_id = x.id and ph.position = 1 and ph.review_status = 'approved'),
         x.why, are_friends(me, x.id)
  from (
    select p.*, intent_fits(me, p.id) as why
    from profiles p
    where p.id <> me and p.status = 'active' and p.city = v.city
      and exists (select 1 from profile_intents i where i.user_id = p.id and (i.expires_at is null or i.expires_at > now()))
      and effective_tier(p.id) <> 'invisible'
      and not ideas_blocked(me, p.id)
  ) x
  where cardinality(x.why) > 0
  order by cardinality(x.why) desc, x.last_active_at desc
  limit least(coalesce(p_limit, 30), 50);
end $$;

-- ---------------------------------------------------------------------
-- Nudges: when you add something new, the best-fitting few hear about it (each at most every 3 days)
-- ---------------------------------------------------------------------
create or replace function public.nudge_intent_matches(p_user uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v profiles;
  r record;
  n int := 0;
begin
  select * into v from profiles where id = p_user;
  if v.status <> 'active' or effective_tier(p_user) = 'invisible' then return 0; end if;
  for r in
    select p.id, intent_fits(p.id, p_user) as why
    from profiles p
    where p.id <> p_user and p.status = 'active' and p.city = v.city
      and exists (select 1 from profile_intents i where i.user_id = p.id and (i.expires_at is null or i.expires_at > now()))
      and not ideas_blocked(p_user, p.id)
      and not exists (select 1 from notifications x where x.user_id = p.id and x.kind = 'intent_match'
                        and x.created_at > now() - interval '3 days')
    order by cardinality(intent_fits(p.id, p_user)) desc, p.last_active_at desc
  loop
    exit when n >= 3;
    continue when cardinality(r.why) = 0;
    perform notify(r.id, 'intent_match',
      'Someone near you fits what you''re up for (' || lower(r.why[1]) || '). See who in You → What I''m up for.');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_intent_options()', 'public.get_my_intents()', 'public.set_my_intents(jsonb)',
    'public.renew_intent(text)', 'public.get_user_intents(uuid)', 'public.get_intent_matches(int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array['public.intent_fits(uuid,uuid)', 'public.nudge_intent_matches(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
