-- Photo review queue. photo-check adds every selfie/photo here when AI checks are off
-- (no AWS keys), so a person can look them over in Table Editor → manual_review
-- and tick `checked`. This table already exists on the live project; this file
-- makes sure a fresh setup has it too. Safe to run again.
create table if not exists public.manual_review (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  photo_id    uuid references public.photos(id) on delete cascade,
  kind        text not null,               -- 'selfie' | 'photo'
  checked     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists manual_review_open on public.manual_review (checked, created_at);
alter table public.manual_review enable row level security; -- no client access (service role only)
