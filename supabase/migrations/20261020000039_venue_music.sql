-- Venue music suggestions (Oct 20 2026). Free for every venue for now.
--  * Only members checked in at the place can suggest and vote.
--  * Songs and albums come from Deezer: cover art and a 30-second preview.
--  * 3 suggestions per person per night. One up or down vote per person per song.
--    A song is voted out once it reaches -3 net. The list resets at closing (6 AM local).
--  * The venue's staff (owner / manager) see tonight's ranked requests and have the final say:
--    mark played, or remove.
--  * Suggestions show the suggester's first name, only to people checked in there (and staff).
-- Safe to re-run.

create table if not exists public.venue_songs (
  id           uuid primary key default gen_random_uuid(),
  place_id     uuid not null references public.places(id) on delete cascade,
  night        date not null,
  kind         text not null check (kind in ('track','album')),
  deezer_id    bigint not null,
  title        text not null check (char_length(title) between 1 and 200),
  artist       text not null check (char_length(artist) between 1 and 200),
  cover        text check (cover ~ '^https://[a-z0-9.-]+\.dzcdn\.net/'),
  preview      text check (preview ~ '^https://[a-z0-9.-]+\.dzcdn\.net/'),
  link         text check (link ~ '^https://(www\.)?deezer\.com/'),
  suggested_by uuid references public.profiles(id) on delete set null,
  status       text not null default 'in' check (status in ('in','out','played','removed')),
  created_at   timestamptz not null default now(),
  unique (place_id, night, kind, deezer_id)
);
create table if not exists public.venue_song_votes (
  song_id    uuid not null references public.venue_songs(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  vote       smallint not null check (vote in (-1, 1)),
  created_at timestamptz not null default now(),
  primary key (song_id, user_id)
);
alter table public.venue_songs enable row level security;        -- functions only
alter table public.venue_song_votes enable row level security;
create index if not exists venue_songs_tonight on public.venue_songs (place_id, night);

-- "Tonight" runs until 6 AM (Calgary time for now; per-city once more cities open)
create or replace function public.music_night()
returns date language sql stable as $$
  select ((now() at time zone 'America/Edmonton') - interval '6 hours')::date;
$$;

-- Where I'm checked in right now (null if nowhere)
create or replace function public.my_checkin_place(p_user uuid default auth.uid())
returns uuid language sql stable security definer set search_path = public as $$
  select place_id from checkins where user_id = p_user and until > now();
$$;

create or replace function public.music_staff(p_place uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from venues v join venue_staff s on s.venue_id = v.id
                  where v.place_id = p_place and s.user_id = p_user);
$$;

create or replace function public.song_net(p_song uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(vote), 0)::int from venue_song_votes where song_id = p_song;
$$;

-- Suggest a song or album. Already on tonight's list? Your suggestion counts as an up-vote instead.
create or replace function public.suggest_song(p_kind text, p_deezer_id bigint, p_title text, p_artist text,
                                               p_cover text default null, p_preview text default null, p_link text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_place uuid := my_checkin_place(auth.uid());
  v_night date := music_night();
  v_id uuid;
  v_left int;
begin
  if v_place is null then raise exception 'Check in where you are to suggest music.'; end if;
  if is_barred(me, v_place) then raise exception 'You can''t suggest music here.'; end if;
  if p_kind not in ('track','album') then raise exception 'Pick a song or an album.'; end if;
  if detect_contact(coalesce(p_title, '') || ' ' || coalesce(p_artist, '')) <> '{}'::text[] then
    raise exception 'That one can''t be suggested.';
  end if;

  select id into v_id from venue_songs where place_id = v_place and night = v_night and kind = p_kind and deezer_id = p_deezer_id;
  if v_id is not null then
    if (select status from venue_songs where id = v_id) in ('out','removed') then
      raise exception 'That one was already voted off tonight.';
    end if;
    insert into venue_song_votes (song_id, user_id, vote) values (v_id, me, 1)
    on conflict (song_id, user_id) do update set vote = 1, created_at = now();
    return jsonb_build_object('id', v_id, 'already', true);
  end if;

  v_left := 3 - (select count(*) from venue_songs where place_id = v_place and night = v_night and suggested_by = me);
  if v_left <= 0 then raise exception 'That''s your 3 for tonight. Vote on the others.'; end if;

  insert into venue_songs (place_id, night, kind, deezer_id, title, artist, cover, preview, link, suggested_by)
  values (v_place, v_night, p_kind, p_deezer_id, left(btrim(p_title), 200), left(btrim(p_artist), 200),
          nullif(p_cover, ''), nullif(p_preview, ''), nullif(p_link, ''), me)
  returning id into v_id;
  insert into venue_song_votes (song_id, user_id, vote) values (v_id, me, 1);
  return jsonb_build_object('id', v_id, 'left', v_left - 1);
end $$;

-- p_vote: 1 up, -1 down, 0 take your vote back
create or replace function public.vote_song(p_song uuid, p_vote int)
returns int language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  s venue_songs;
  v_net int;
begin
  select * into s from venue_songs where id = p_song;
  if s.id is null or s.night <> music_night() then raise exception 'That one''s from another night.'; end if;
  if my_checkin_place(me) is distinct from s.place_id then raise exception 'Check in here to vote.'; end if;
  if s.status in ('out','removed') then raise exception 'That one''s already off the list.'; end if;
  if coalesce(p_vote, 0) = 0 then
    delete from venue_song_votes where song_id = s.id and user_id = me;
  else
    insert into venue_song_votes (song_id, user_id, vote) values (s.id, me, sign(p_vote)::smallint)
    on conflict (song_id, user_id) do update set vote = excluded.vote, created_at = now();
  end if;
  v_net := song_net(s.id);
  if v_net <= -3 and s.status = 'in' then
    update venue_songs set status = 'out' where id = s.id;
  end if;
  return v_net;
end $$;

-- Tonight's list, ranked. For people checked in here, and the venue's staff.
create or replace function public.tonight_songs(p_place uuid default null)
returns table (id uuid, kind text, deezer_id bigint, title text, artist text, cover text, preview text, link text,
               net int, ups int, downs int, my_vote int, suggested_by text, mine boolean, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  v_place uuid := coalesce(p_place, my_checkin_place(auth.uid()));
begin
  if v_place is null then return; end if;
  if my_checkin_place(me) is distinct from v_place and not music_staff(v_place, me) then
    raise exception 'Check in here to see tonight''s music.';
  end if;
  return query
  select s.id, s.kind, s.deezer_id, s.title, s.artist, s.cover, s.preview, s.link,
         song_net(s.id),
         (select count(*)::int from venue_song_votes v where v.song_id = s.id and v.vote = 1),
         (select count(*)::int from venue_song_votes v where v.song_id = s.id and v.vote = -1),
         coalesce((select v.vote::int from venue_song_votes v where v.song_id = s.id and v.user_id = me), 0),
         split_part(coalesce(p.display_name, ''), ' ', 1),
         s.suggested_by = me,
         s.status, s.created_at
  from venue_songs s left join profiles p on p.id = s.suggested_by
  where s.place_id = v_place and s.night = music_night() and s.status <> 'removed'
    and (s.status <> 'out' or music_staff(v_place, me))
  order by case s.status when 'in' then 0 when 'played' then 1 else 2 end, song_net(s.id) desc, s.created_at;
end $$;

-- How many suggestions I have left tonight where I'm checked in
create or replace function public.my_song_suggestions_left()
returns int language sql stable security definer set search_path = public as $$
  select case when my_checkin_place(auth.uid()) is null then 0 else
    greatest(0, 3 - (select count(*)::int from venue_songs
                      where place_id = my_checkin_place(auth.uid()) and night = music_night() and suggested_by = auth.uid())) end;
$$;

-- Staff: final say. 'played', 'removed', or 'in' (put it back)
create or replace function public.staff_set_song(p_song uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare s venue_songs;
begin
  select * into s from venue_songs where id = p_song;
  if s.id is null or not music_staff(s.place_id, auth.uid()) then raise exception 'Not allowed.'; end if;
  if p_status not in ('played','removed','in') then raise exception 'Unknown status.'; end if;
  update venue_songs set status = p_status where id = s.id;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.suggest_song(text,bigint,text,text,text,text,text)', 'public.vote_song(uuid,int)',
    'public.tonight_songs(uuid)', 'public.my_song_suggestions_left()', 'public.staff_set_song(uuid,text)',
    'public.my_checkin_place(uuid)', 'public.music_staff(uuid,uuid)', 'public.song_net(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
