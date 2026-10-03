-- Circles run themselves.
--  * Anyone can start a circle (up to 30 people). Nobody is placed in one by the app any more.
--  * To bring someone in, a member nominates them. The invite goes out once 25% of the circle + 1
--    have said yes (the nominator counts). No vetoes. Voting closes after 7 days.
--  * The person never sees the nomination or the votes: an invite either arrives or it quietly doesn't.
--  * Suggested people: who shares the circle's interests, goes to the same spots and events, and lives nearby.
--  * A circle's home area is worked out from where its members actually meet.

alter table public.circles drop constraint if exists circles_max_size_check;
alter table public.circles add constraint circles_max_size_check check (max_size between 2 and 30);
alter table public.circles alter column max_size set default 30;
update public.circles set max_size = 30 where max_size < 30;
alter table public.circles add column if not exists created_by uuid references public.profiles(id) on delete set null;

create table if not exists public.circle_nominations (
  id           uuid primary key default gen_random_uuid(),
  circle_id    uuid not null references public.circles(id) on delete cascade,
  nominee      uuid not null references public.profiles(id) on delete cascade,
  nominated_by uuid references public.profiles(id) on delete set null,
  note         text check (char_length(note) <= 200),
  status       text not null default 'voting'
               check (status in ('voting','invited','joined','declined','not_enough','expired')),
  created_at   timestamptz not null default now(),
  closes_at    timestamptz not null default now() + interval '7 days',
  decided_at   timestamptz
);
create unique index if not exists circle_nominations_open
  on public.circle_nominations (circle_id, nominee) where status in ('voting','invited');

create table if not exists public.circle_votes (
  nomination_id uuid references public.circle_nominations(id) on delete cascade,
  voter         uuid references public.profiles(id) on delete cascade,
  yes           boolean not null,
  created_at    timestamptz not null default now(),
  primary key (nomination_id, voter)
);

alter table public.circle_nominations enable row level security;  -- functions only
alter table public.circle_votes       enable row level security;

-- Yes votes needed: 25% of the circle + 1 (the circle size when the vote is counted)
create or replace function public.circle_votes_needed(p_circle uuid)
returns int language sql stable security definer set search_path = public as $$
  select floor((select count(*) from circle_members where circle_id = p_circle) * 0.25)::int + 1;
$$;

-- Count the votes and move the nomination along. Called after every vote and by the daily sweep.
create or replace function public.settle_nomination(p_nom uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  n circle_nominations;
  c circles;
  v_yes int;
  v_no int;
  v_eligible int;
  v_need int;
begin
  select * into n from circle_nominations where id = p_nom for update;
  if n.id is null or n.status <> 'voting' then return n.status; end if;
  select * into c from circles where id = n.circle_id;

  v_need := circle_votes_needed(n.circle_id);
  select count(*) filter (where v.yes), count(*) filter (where not v.yes) into v_yes, v_no
  from circle_votes v join circle_members m on m.circle_id = n.circle_id and m.user_id = v.voter
  where v.nomination_id = n.id;
  select count(*) into v_eligible from circle_members where circle_id = n.circle_id;

  if (select count(*) from circle_members where circle_id = n.circle_id) >= c.max_size then
    if n.closes_at < now() then
      update circle_nominations set status = 'expired', decided_at = now() where id = n.id;
      return 'expired';
    end if;
    return 'voting';  -- full right now; wait for a spot until voting closes
  end if;

  if v_yes >= v_need then
    update circle_nominations set status = 'invited', decided_at = now() where id = n.id;
    perform notify(n.nominee, 'circle_invite', 'You''re invited to join ' || c.name || '.');
    return 'invited';
  end if;
  if v_yes + (v_eligible - v_yes - v_no) < v_need then          -- can't reach the bar any more
    update circle_nominations set status = 'not_enough', decided_at = now() where id = n.id;
    return 'not_enough';
  end if;
  if n.closes_at < now() then
    update circle_nominations set status = 'not_enough', decided_at = now() where id = n.id;
    return 'not_enough';
  end if;
  return 'voting';
end $$;

-- ---------------------------------------------------------------------
-- Starting and joining
-- ---------------------------------------------------------------------
create or replace function public.create_circle(p_name text, p_topic int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_id uuid;
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Give your circle a name.'; end if;
  if (select count(*) from circle_members where user_id = me) >= 10 then
    raise exception 'You''re in 10 circles already. Leave one to start another.';
  end if;
  select * into v from profiles where id = me;
  insert into circles (name, topic_id, lat, lng, max_size, created_by)
  values (left(btrim(p_name), 60), p_topic, v.lat, v.lng, 30, me)
  returning id into v_id;
  insert into circle_members (circle_id, user_id) values (v_id, me);
  return v_id;
end $$;

-- Circles are invite-only now: the old "place me" and "join" paths are closed
create or replace function public.join_circle(p_circle uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Circles are invite only. A member can nominate you.';
end $$;

create or replace function public.find_my_circle()
returns uuid language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Circles are invite only now. Start your own, or get nominated by a member.';
end $$;

-- ---------------------------------------------------------------------
-- Nominating and voting (members only; the nominee never sees any of this)
-- ---------------------------------------------------------------------
create or replace function public.nominate_to_circle(p_circle uuid, p_user uuid, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_id uuid;
begin
  if not is_circle_member(p_circle, me) then raise exception 'Not in this circle.'; end if;
  if p_user = me or is_circle_member(p_circle, p_user) then raise exception 'They''re already in.'; end if;
  if coalesce((select status from profiles where id = p_user), '') <> 'active' then raise exception 'That person isn''t available.'; end if;
  if exists (select 1 from circle_members m join blocks b
               on (b.blocker = m.user_id and b.blocked = p_user) or (b.blocker = p_user and b.blocked = m.user_id)
             where m.circle_id = p_circle) then
    raise exception 'That person isn''t available.';
  end if;
  if exists (select 1 from circle_nominations where circle_id = p_circle and nominee = p_user and status in ('voting','invited')) then
    raise exception 'Already nominated.';
  end if;
  -- A quiet "no" holds for 30 days
  if exists (select 1 from circle_nominations where circle_id = p_circle and nominee = p_user
               and status in ('not_enough','declined') and decided_at > now() - interval '30 days') then
    raise exception 'They were considered recently. Try again later.';
  end if;
  if (select count(*) from circle_nominations where nominated_by = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'That''s a lot of nominations today. Try tomorrow.';
  end if;

  insert into circle_nominations (circle_id, nominee, nominated_by, note)
  values (p_circle, p_user, me, left(btrim(p_note), 200))
  returning id into v_id;
  insert into circle_votes (nomination_id, voter, yes) values (v_id, me, true);

  -- Let the other members know there's someone to vote on
  perform notify(m.user_id, 'circle_vote',
                 (select display_name from profiles where id = me) || ' nominated someone for '
                 || (select name from circles where id = p_circle) || '. Have your say.')
  from circle_members m where m.circle_id = p_circle and m.user_id <> me;

  return settle_nomination(v_id);
end $$;

create or replace function public.vote_on_nomination(p_nom uuid, p_yes boolean)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  n circle_nominations;
begin
  select * into n from circle_nominations where id = p_nom;
  if n.id is null or not is_circle_member(n.circle_id, me) then raise exception 'Not in this circle.'; end if;
  if n.status <> 'voting' then return n.status; end if;
  insert into circle_votes (nomination_id, voter, yes) values (p_nom, me, coalesce(p_yes, false))
  on conflict (nomination_id, voter) do update set yes = excluded.yes, created_at = now();
  return settle_nomination(p_nom);
end $$;

-- What members see on a circle's "Grow" tab
create or replace function public.get_circle_nominations(p_circle uuid)
returns table (nomination_id uuid, user_id uuid, name text, photo text, nominated_by text, note text,
               status text, yes int, needed int, my_vote boolean, closes_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare me uuid := require_tester();
begin
  if not is_circle_member(p_circle, me) then raise exception 'Not in this circle.'; end if;
  perform settle_nomination(n.id) from circle_nominations n where n.circle_id = p_circle and n.status = 'voting';
  return query
  select n.id, p.id, p.display_name,
         (select ph.storage_path from photos ph where ph.user_id = p.id and ph.position = 1 and ph.review_status = 'approved'),
         (select display_name from profiles where id = n.nominated_by), n.note, n.status,
         (select count(*)::int from circle_votes v where v.nomination_id = n.id and v.yes),
         circle_votes_needed(p_circle),
         (select v.yes from circle_votes v where v.nomination_id = n.id and v.voter = me),
         n.closes_at
  from circle_nominations n join profiles p on p.id = n.nominee
  where n.circle_id = p_circle
    and (n.status in ('voting','invited') or n.decided_at > now() - interval '7 days')
  order by (n.status = 'voting') desc, (select v.yes from circle_votes v where v.nomination_id = n.id and v.voter = me) nulls first,
           n.created_at desc;
end $$;

-- ---------------------------------------------------------------------
-- The person's side: just an invite (no votes, no nominator shown)
-- ---------------------------------------------------------------------
create or replace function public.get_my_circle_invites()
returns table (nomination_id uuid, circle_id uuid, name text, topic text, members int, invited_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  return query
  select n.id, c.id, c.name, t.name, (select count(*)::int from circle_members m where m.circle_id = c.id), n.decided_at
  from circle_nominations n join circles c on c.id = n.circle_id left join topics t on t.id = c.topic_id
  where n.nominee = me and n.status = 'invited'
  order by n.decided_at desc;
end $$;

create or replace function public.answer_circle_invite(p_nom uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  n circle_nominations;
  c circles;
begin
  select * into n from circle_nominations where id = p_nom and nominee = me for update;
  if n.id is null or n.status <> 'invited' then raise exception 'That invite is no longer open.'; end if;
  if not p_accept then
    update circle_nominations set status = 'declined', decided_at = now() where id = n.id;
    return;
  end if;
  select * into c from circles where id = n.circle_id;
  if (select count(*) from circle_members where circle_id = c.id) >= c.max_size then
    raise exception 'This circle is full right now.';
  end if;
  if (select count(*) from circle_members where user_id = me) >= 10 then
    raise exception 'You''re in 10 circles already. Leave one first.';
  end if;
  insert into circle_members (circle_id, user_id) values (c.id, me) on conflict do nothing;
  update circle_nominations set status = 'joined', decided_at = now() where id = n.id;
  perform notify(m.user_id, 'circle_joined', (select display_name from profiles where id = me) || ' joined ' || c.name || '.')
  from circle_members m where m.circle_id = c.id and m.user_id <> me;
end $$;

-- ---------------------------------------------------------------------
-- Home area and suggested people
-- ---------------------------------------------------------------------
-- Where the circle actually meets: its pinned plans and members' saved spots; else where members live
create or replace function public.circle_home(p_circle uuid)
returns table (lat double precision, lng double precision)
language sql stable security definer set search_path = public as $$
  with pts as (
    select pl.lat, pl.lng, 3 as w from events e join places pl on pl.id = e.place_id
     where e.circle_id = p_circle and e.created_at > now() - interval '120 days'
    union all
    select pl.lat, pl.lng, 1 from circle_members m join saved_places s on s.user_id = m.user_id
      join places pl on pl.id = s.place_id where m.circle_id = p_circle
  ),
  homes as (
    select p.lat, p.lng from circle_members m join profiles p on p.id = m.user_id
     where m.circle_id = p_circle and p.lat is not null
  )
  select coalesce((select sum(lat * w) / sum(w) from pts), (select avg(lat) from homes), (select lat from circles where id = p_circle)),
         coalesce((select sum(lng * w) / sum(w) from pts), (select avg(lng) from homes), (select lng from circles where id = p_circle));
$$;

create or replace function public.update_circle_homes()
returns void language sql security definer set search_path = public as $$
  update circles c set lat = h.lat, lng = h.lng
  from (select c2.id, (circle_home(c2.id)).* from circles c2) h
  where h.id = c.id and h.lat is not null;
$$;
select cron.schedule('circle-homes', '41 4 * * *', $$select public.update_circle_homes()$$);

-- People the circle might want: shared interests, same spots and events, nearby. Never people
-- already in, already nominated, recently turned down, or blocked by anyone in the circle.
create or replace function public.get_circle_candidates(p_circle uuid)
returns table (user_id uuid, name text, photo text, reasons text[], distance_km int)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := require_tester();
  h record;
begin
  if not is_circle_member(p_circle, me) then raise exception 'Not in this circle.'; end if;
  select * into h from circle_home(p_circle);
  return query
  with mem as (select m.user_id as uid from circle_members m where m.circle_id = p_circle),
  cand as (
    select p.id, p.display_name, p.lat, p.lng,
      (select count(distinct a.topic_id)::int from user_topics a join user_topics b on b.topic_id = a.topic_id
        where a.user_id = p.id and b.user_id in (select uid from mem)) as shared_topics,
      (select count(distinct s.place_id)::int from saved_places s join saved_places t on t.place_id = s.place_id
        where s.user_id = p.id and t.user_id in (select uid from mem)) as shared_spots,
      (select count(distinct r.event_id)::int from event_rsvps r join event_rsvps q on q.event_id = r.event_id
        where r.user_id = p.id and q.user_id in (select uid from mem)) as shared_events,
      (select count(*)::int from friendships f where f.status = 'accepted'
        and ((f.user_a = p.id and f.user_b in (select uid from mem)) or (f.user_b = p.id and f.user_a in (select uid from mem)))) as friends_in
    from profiles p
    where p.status = 'active' and p.is_tester
      and p.id not in (select uid from mem)
      and not exists (select 1 from circle_nominations n where n.circle_id = p_circle and n.nominee = p.id
                        and (n.status in ('voting','invited') or n.decided_at > now() - interval '30 days'))
      and not exists (select 1 from blocks b join mem on (b.blocker = mem.uid and b.blocked = p.id)
                                                       or (b.blocker = p.id and b.blocked = mem.uid))
      and (h.lat is null or p.lat is null or haversine_km(h.lat, h.lng, p.lat, p.lng) <= 40)
  )
  select c.id, c.display_name,
         (select ph.storage_path from photos ph where ph.user_id = c.id and ph.position = 1 and ph.review_status = 'approved'),
         array_remove(array[
           case when c.friends_in = 1 then 'Friends with 1 member' when c.friends_in > 1 then 'Friends with ' || c.friends_in || ' members' end,
           case when c.shared_events > 0 then 'Same events' end,
           case when c.shared_spots > 0 then 'Same spots' end,
           case when c.shared_topics > 0 then c.shared_topics || ' shared interest' || case when c.shared_topics > 1 then 's' else '' end end
         ], null),
         case when h.lat is null or c.lat is null then null else greatest(1, round(haversine_km(h.lat, h.lng, c.lat, c.lng)))::int end
  from cand c
  where c.shared_topics + c.shared_spots + c.shared_events + c.friends_in > 0
  order by c.friends_in * 4 + c.shared_events * 3 + c.shared_spots * 2 + c.shared_topics
           - case when h.lat is null or c.lat is null then 0 else haversine_km(h.lat, h.lng, c.lat, c.lng) / 10 end desc
  limit 12;
end $$;

-- Daily: close votes that ran out of time
create or replace function public.sweep_nominations()
returns void language sql security definer set search_path = public as $$
  select settle_nomination(id) from circle_nominations where status = 'voting' and closes_at < now();
  update circle_nominations set status = 'expired', decided_at = now()
   where status = 'invited' and decided_at < now() - interval '30 days';
$$;
select cron.schedule('sweep-nominations', '11 * * * *', $$select public.sweep_nominations()$$);

-- Push titles for the new notices
create or replace function public.tg_notification_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform send_push(new.user_id,
    case new.kind
      when 'match'            then 'New match'
      when 'call_proposed'    then 'Call request'
      when 'call_accepted'    then 'Call confirmed'
      when 'call_rescheduled' then 'Call moved'
      when 'call_soon'        then 'Call starting soon'
      when 'no_show'          then 'Missed call'
      when 'call_missed'      then 'Missed call'
      when 'match_expired'    then 'Match expired'
      when 'match_ended'      then 'Match ended'
      when 'contact_unlocked' then 'Numbers unlocked'
      when 'paused'           then 'Account paused'
      when 'unpaused'         then 'You''re visible again'
      when 'friend_request'   then 'Friend request'
      when 'friend_accepted'  then 'New friend'
      when 'event_invite'     then 'You''re invited'
      when 'here_now'         then 'Here now'
      when 'circle_invite'    then 'Circle invite'
      when 'circle_vote'      then 'New nomination'
      when 'circle_joined'    then 'New member'
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;

-- Permissions
do $$
declare f text;
begin
  foreach f in array array[
    'public.create_circle(text,int)', 'public.nominate_to_circle(uuid,uuid,text)', 'public.vote_on_nomination(uuid,boolean)',
    'public.get_circle_nominations(uuid)', 'public.get_my_circle_invites()', 'public.answer_circle_invite(uuid,boolean)',
    'public.get_circle_candidates(uuid)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  foreach f in array array[
    'public.circle_votes_needed(uuid)', 'public.settle_nomination(uuid)', 'public.circle_home(uuid)',
    'public.update_circle_homes()', 'public.sweep_nominations()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
