-- House rules and conduct strikes (Nov 3 2026):
--  * Every member accepts the house rules once ("I'm in") before using the app:
--      1. No photos of other members without asking.
--      2. What happens in the room stays in the room (no sharing others' plans or check-ins).
--      3. Respect the venues and their staff.
--      4. Be real: no fake profiles, no selling.
--      5. Keep the door closed: don't post about the app publicly.
--  * Breaking one is punishable, scaled to how serious it is (the owner decides, as admin):
--      - minor slip (e.g. snapping a photo): a warning first; the same rule again within a year is a strike
--      - serious (e.g. assaulting staff, violence): straight to a strike, with a warning notice
--  * A strike puts a neutral "Conduct strike" mark on the profile. It ages off after 12 months, can be
--    appealed, and the owner can lift it. Three strikes at once = account suspended for review.
--  * Members can report a house-rule break from any profile.
--  NOTE: get a lawyer to look at the public mark before launch.
-- Safe to re-run.

alter table public.profiles add column if not exists house_rules_at timestamptz;

-- Everyone who's already a member when this ships still sees the rules once on their next open
-- (nothing to backfill).

alter table public.reports drop constraint if exists reports_category_check;
alter table public.reports add constraint reports_category_check
  check (category in ('fake_profile','harassment','scam','explicit','underage','threats','spam','house_rules','other'));

create table if not exists public.conduct_strikes (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  rule         text not null check (rule in ('photos','room','respect','real','door','violence')),
  level        text not null check (level in ('warning','strike')),
  note         text check (char_length(note) <= 500),          -- what they're told
  admin_id     uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz,                                    -- strikes: 12 months; warnings: null
  lifted_at    timestamptz,
  appeal       text check (char_length(appeal) <= 1000),
  appealed_at  timestamptz,
  appeal_note  text check (char_length(appeal_note) <= 500)    -- the owner's answer
);
create index if not exists conduct_strikes_user on public.conduct_strikes (user_id, created_at desc);
alter table public.conduct_strikes enable row level security;  -- functions only

-- One place for the wording (the app reads it from house_rules())
create or replace function public.house_rules()
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('rule','photos',  'title','No photos of other members without asking.',
                       'body','Ask first. Every time.'),
    jsonb_build_object('rule','room',    'title','What happens in the room stays in the room.',
                       'body','Don''t share other people''s plans, check-ins or who you saw.'),
    jsonb_build_object('rule','respect', 'title','Respect the venues and their staff.',
                       'body','They let us in. Treat their place and their people well.'),
    jsonb_build_object('rule','real',    'title','Be real.',
                       'body','No fake profiles, no selling, no pretending to be someone you''re not.'),
    jsonb_build_object('rule','door',    'title','Keep the door closed.',
                       'body','Don''t post about the app publicly. People get in through people.'));
$$;

create or replace function public.rule_title(p_rule text)
returns text language sql immutable as $$
  select case p_rule when 'violence' then 'No violence or threats.'
                     else (select e ->> 'title' from jsonb_array_elements(house_rules()) e where e ->> 'rule' = p_rule) end;
$$;

create or replace function public.my_house_rules()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('accepted', (select house_rules_at is not null from profiles where id = auth.uid()),
                            'rules', house_rules());
$$;

create or replace function public.accept_house_rules()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in again.'; end if;
  update profiles set house_rules_at = coalesce(house_rules_at, now()) where id = auth.uid();
end $$;

-- Members can't set the acceptance time themselves (only through accept_house_rules)
create or replace function public.tg_profile_rules_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    if tg_op = 'INSERT' then new.house_rules_at := null; else new.house_rules_at := old.house_rules_at; end if;
  end if;
  return new;
end $$;
drop trigger if exists profile_rules_guard on public.profiles;
create trigger profile_rules_guard before insert or update on public.profiles
for each row execute function public.tg_profile_rules_guard();

create or replace function public.active_strikes(p_user uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from conduct_strikes
  where user_id = p_user and level = 'strike' and lifted_at is null and expires_at > now();
$$;

-- What other members see: just whether there's an active strike (neutral wording, no details)
create or replace function public.get_conduct_mark(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and active_strikes(p_user) > 0;
$$;

-- ---------------------------------------------------------------------
-- The owner (admin) records a house-rule break
--  p_serious: null = decide from the rule (violence is serious, everything else starts as a warning)
--  Returns the level given: 'warning' or 'strike'
-- ---------------------------------------------------------------------
create or replace function public.admin_conduct(p_user uuid, p_rule text, p_note text default null, p_serious boolean default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  v_serious boolean := coalesce(p_serious, p_rule = 'violence');
  v_level text;
  v_msg text;
begin
  if p_rule not in ('photos','room','respect','real','door','violence') then raise exception 'Pick a rule.'; end if;
  if not exists (select 1 from profiles where id = p_user) then raise exception 'No such member.'; end if;

  if v_serious then
    v_level := 'strike';
  elsif exists (select 1 from conduct_strikes where user_id = p_user and rule = p_rule
                and created_at > now() - interval '12 months' and lifted_at is null) then
    v_level := 'strike';   -- same rule again within a year
  else
    v_level := 'warning';
  end if;

  insert into conduct_strikes (user_id, rule, level, note, admin_id, expires_at)
  values (p_user, p_rule, v_level, nullif(btrim(coalesce(p_note, '')), ''), me,
          case when v_level = 'strike' then now() + interval '12 months' end);

  insert into moderation_actions (user_id, action, note, admin_id)
  values (p_user, 'warn', left(case when v_level = 'strike' then 'Conduct strike: ' else 'House-rule warning: ' end
                               || rule_title(p_rule) || coalesce(' ' || nullif(btrim(coalesce(p_note, '')), ''), ''), 500), me);

  v_msg := case when v_level = 'strike'
    then 'A conduct strike was added to your profile for breaking a house rule: ' || rule_title(p_rule)
         || ' It shows on your profile for 12 months. You can appeal it under You → Your standing.'
    else 'A warning about a house rule: ' || rule_title(p_rule)
         || ' This one is just a warning. Next time it''s a strike on your profile.' end;
  if nullif(btrim(coalesce(p_note, '')), '') is not null then v_msg := v_msg || ' Note: ' || btrim(p_note); end if;
  perform notify(p_user, 'warning', left(v_msg, 900));

  -- three active strikes: suspended while the owner reviews
  if v_level = 'strike' and active_strikes(p_user) >= 3 then
    update profiles set status = 'suspended', pause_reason = 'Under review' where id = p_user and status = 'active';
  end if;
  return v_level;
end $$;

-- Your own standing: warnings and strikes, with appeal state
create or replace function public.get_my_conduct()
returns table (strike_id uuid, rule text, rule_title text, level text, note text, created_at timestamptz,
               expires_at timestamptz, active boolean, appeal text, appealed_at timestamptz, appeal_note text)
language sql stable security definer set search_path = public as $$
  select s.id, s.rule, rule_title(s.rule), s.level, s.note, s.created_at, s.expires_at,
         s.level = 'strike' and s.lifted_at is null and s.expires_at > now(),
         s.appeal, s.appealed_at, s.appeal_note
  from conduct_strikes s
  where s.user_id = auth.uid() and s.created_at > now() - interval '24 months'
  order by s.created_at desc;
$$;

create or replace function public.appeal_strike(p_strike uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if char_length(btrim(coalesce(p_text, ''))) < 10 then raise exception 'Tell us what happened (a sentence or two).'; end if;
  update conduct_strikes set appeal = left(btrim(p_text), 1000), appealed_at = now()
   where id = p_strike and user_id = auth.uid() and level = 'strike' and lifted_at is null
     and expires_at > now() and appealed_at is null;
  if not found then raise exception 'That strike can''t be appealed (already appealed, or no longer active).'; end if;
end $$;

-- Admin: strikes and warnings for one member, and the appeals waiting on you
create or replace function public.admin_member_conduct(p_user uuid)
returns table (strike_id uuid, rule text, rule_title text, level text, note text, created_at timestamptz,
               expires_at timestamptz, active boolean, appeal text, appealed_at timestamptz, appeal_note text, lifted_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select s.id, s.rule, rule_title(s.rule), s.level, s.note, s.created_at, s.expires_at,
         s.level = 'strike' and s.lifted_at is null and s.expires_at > now(),
         s.appeal, s.appealed_at, s.appeal_note, s.lifted_at
  from conduct_strikes s where s.user_id = p_user order by s.created_at desc;
end $$;

create or replace function public.admin_strike_appeals()
returns table (strike_id uuid, user_id uuid, name text, rule_title text, note text, created_at timestamptz,
               appeal text, appealed_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_admin();
  return query
  select s.id, s.user_id, p.display_name, rule_title(s.rule), s.note, s.created_at, s.appeal, s.appealed_at
  from conduct_strikes s join profiles p on p.id = s.user_id
  where s.appealed_at is not null and s.appeal_note is null and s.lifted_at is null
  order by s.appealed_at;
end $$;

-- p_lift: true = the strike comes off; false = it stays. Either way they're told.
create or replace function public.admin_decide_strike(p_strike uuid, p_lift boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_admin();
  s conduct_strikes;
begin
  select * into s from conduct_strikes where id = p_strike for update;
  if s.id is null then raise exception 'No such strike.'; end if;
  update conduct_strikes
     set lifted_at = case when p_lift then now() else lifted_at end,
         appeal_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), case when p_lift then 'Lifted.' else 'Upheld.' end)
   where id = p_strike;
  insert into moderation_actions (user_id, action, note, admin_id)
  values (s.user_id, case when p_lift then 'reinstate' else 'dismiss' end,
          left(case when p_lift then 'Conduct strike lifted' else 'Conduct strike upheld' end
               || coalesce(': ' || nullif(btrim(coalesce(p_note, '')), ''), ''), 500), me);
  perform notify(s.user_id, 'warning',
    case when p_lift then 'Your conduct strike was lifted. It no longer shows on your profile.'
         else 'We looked at your appeal. The conduct strike stays for now.' end
    || coalesce(' ' || nullif(btrim(coalesce(p_note, '')), ''), ''));
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.my_house_rules()', 'public.accept_house_rules()', 'public.get_conduct_mark(uuid)',
    'public.get_my_conduct()', 'public.appeal_strike(uuid,text)',
    'public.admin_conduct(uuid,text,text,boolean)', 'public.admin_member_conduct(uuid)',
    'public.admin_strike_appeals()', 'public.admin_decide_strike(uuid,boolean,text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  execute 'revoke all on function public.active_strikes(uuid) from public, anon, authenticated';
end $$;
