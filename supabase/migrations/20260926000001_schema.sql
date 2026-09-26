-- =====================================================================
-- Based Dating v1 — core schema
-- Run in order: 0001_schema → 0002_rules → 0003_feed → 0004_safety → 0005_security
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Profiles (public-ish data only; hidden scores live in user_scores)
-- ---------------------------------------------------------------------
create table public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  display_name     text not null check (char_length(display_name) between 1 and 40),
  birthdate        date not null check (birthdate <= (current_date - interval '18 years')),
  gender           text not null check (gender in ('man','woman')),
  seeking          text[] not null check (seeking <@ array['man','woman'] and cardinality(seeking) > 0),
  lat              double precision,
  lng              double precision,
  availability     jsonb not null default '{}'::jsonb,   -- {"mon":["evening"],"sat":["morning","afternoon"]}
  scenario_answers jsonb not null default '{}'::jsonb,   -- never shown on profile
  feed_range       text not null default 'global'
                   check (feed_range in ('local','region','province','country','global')),
  status           text not null default 'onboarding'
                   check (status in ('onboarding','active','paused','suspended','banned')),
  pause_reason     text,
  selfie_verified  boolean not null default false,
  selfie_path      text,
  ad_free          boolean not null default false,
  created_at       timestamptz not null default now(),
  last_active_at   timestamptz not null default now()
);

-- Hidden per-user scores. No client policies => clients can never read these.
create table public.user_scores (
  user_id           uuid primary key references public.profiles(id) on delete cascade,
  desirability      real not null default 0.5 check (desirability between 0 and 1),
  engagement_score  real not null default 1.0,
  tier              text not null default 'healthy'
                    check (tier in ('healthy','slipping','low','invisible')),
  nudges_sent       int  not null default 0,
  last_nudged_at    timestamptz,
  computed_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Photos: 3 required clear-face shots, up to 3 optional looser shots
-- ---------------------------------------------------------------------
create table public.photos (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  storage_path  text not null,
  position      int  not null check (position between 1 and 6),
  -- set by the photo-check function (AI), never by the client
  review_status text not null default 'pending' check (review_status in ('pending','approved','rejected')),
  shows_user    boolean,      -- the verified user is in the photo (face match or body match)
  clear_face    boolean,      -- facing camera, face clearly visible, user alone
  reject_reason text,
  created_at    timestamptz not null default now(),
  unique (user_id, position)
);

-- ---------------------------------------------------------------------
-- Interests
-- ---------------------------------------------------------------------
create table public.topics (
  id    serial primary key,
  slug  text unique not null,
  name  text not null
);

create table public.user_topics (
  user_id  uuid references public.profiles(id) on delete cascade,
  topic_id int  references public.topics(id) on delete cascade,
  primary key (user_id, topic_id)
);

-- ---------------------------------------------------------------------
-- Likes / passes / matches
-- ---------------------------------------------------------------------
create table public.likes (
  from_user  uuid references public.profiles(id) on delete cascade,
  to_user    uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_user, to_user),
  check (from_user <> to_user)
);

create table public.passes (
  from_user  uuid references public.profiles(id) on delete cascade,
  to_user    uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_user, to_user)
);

create table public.matches (
  id                 uuid primary key default gen_random_uuid(),
  user_a             uuid not null references public.profiles(id) on delete cascade,
  user_b             uuid not null references public.profiles(id) on delete cascade,
  created_at         timestamptz not null default now(),
  call_deadline      timestamptz not null default (now() + interval '3 days'),
  max_deadline       timestamptz not null default (now() + interval '5 days'), -- 3 days + max 48h reschedule
  reschedules_used   int  not null default 0 check (reschedules_used between 0 and 2),
  call_done          boolean not null default false,   -- any completed 5+ min call
  video_call_done    boolean not null default false,   -- completed 5+ min video call
  call_completed_at  timestamptz,
  contact_unlocked   boolean not null default false,   -- phone numbers allowed
  status             text not null default 'active' check (status in ('active','ended')),
  ended_by           uuid,
  end_reason         text check (end_reason in ('not_feeling_it','expired','no_show','report','reschedules_exhausted','deleted')),
  ended_at           timestamptz,
  icebreaker         text,
  check (user_a < user_b),
  unique (user_a, user_b)
);

create table public.messages (
  id           uuid primary key default gen_random_uuid(),
  match_id     uuid not null references public.matches(id) on delete cascade,
  sender_id    uuid not null references public.profiles(id) on delete cascade,
  body         text not null check (char_length(body) between 1 and 2000),
  status       text not null default 'sent' check (status in ('sent','blocked','flagged')),
  block_reason text,
  created_at   timestamptz not null default now()
);

create table public.calls (
  id               uuid primary key default gen_random_uuid(),
  match_id         uuid not null references public.matches(id) on delete cascade,
  proposed_by      uuid not null references public.profiles(id),
  kind             text not null default 'voice' check (kind in ('voice','video')),
  scheduled_for    timestamptz not null,
  status           text not null default 'proposed'
                   check (status in ('proposed','accepted','completed','short','missed','cancelled')),
  started_at       timestamptz,
  ended_at         timestamptz,
  duration_seconds int,
  ended_by         uuid,
  end_reason       text check (end_reason in ('normal','early','report','connection')),
  no_show_user     uuid,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Engagement events (feed the hidden score; 30-day rolling window)
-- ---------------------------------------------------------------------
create table public.engagement_events (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,   -- no_show, contact_violation, early_hangup, hostile_comment, expired_unresponsive
  weight     real not null,   -- penalty size (positive = worse)
  match_id   uuid,
  created_at timestamptz not null default now()
);

create table public.notifications (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  body       text not null,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
create index on public.profiles (status);
create index on public.photos (user_id);
create index on public.matches (user_a, status);
create index on public.matches (user_b, status);
create index on public.matches (status, call_deadline);
create index on public.messages (match_id, created_at);
create index on public.calls (match_id);
create index on public.engagement_events (user_id, created_at);
create index on public.likes (to_user);

-- Seed interest topics
insert into public.topics (slug, name) values
 ('hiking','Hiking'),('fishing','Fishing'),('hunting','Hunting'),('camping','Camping'),
 ('trucks','Trucks'),('cars','Cars'),('motorcycles','Motorcycles'),('offroad','Off-roading'),
 ('fitness','Fitness'),('martial-arts','Martial arts'),('hockey','Hockey'),('football','Football'),
 ('business','Business'),('investing','Investing'),('trades','Trades & building'),('tech','Tech'),
 ('gaming','Gaming'),('music','Music'),('cooking','Cooking'),('bbq','BBQ'),
 ('travel','Travel'),('dogs','Dogs'),('horses','Horses'),('faith','Faith'),
 ('reading','Reading'),('film','Movies & TV'),('diy','DIY'),('gardening','Gardening'),
 ('photography','Photography'),('art','Art');

-- Blocks (referenced by matching)
create table public.blocks (
  blocker    uuid references public.profiles(id) on delete cascade,
  blocked    uuid references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);
