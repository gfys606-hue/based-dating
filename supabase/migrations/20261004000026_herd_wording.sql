-- New names: "Herd" replaces "Circles" in everything people read (the tables keep their names).

create or replace function public.create_circle(p_name text, p_topic int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v profiles;
  v_id uuid;
begin
  if char_length(btrim(coalesce(p_name, ''))) < 2 then raise exception 'Give your herd a name.'; end if;
  if (select count(*) from circle_members where user_id = me) >= 10 then
    raise exception 'You''re in 10 herds already. Leave one to start another.';
  end if;
  select * into v from profiles where id = me;
  insert into circles (name, topic_id, lat, lng, max_size, created_by)
  values (left(btrim(p_name), 60), p_topic, v.lat, v.lng, 30, me)
  returning id into v_id;
  insert into circle_members (circle_id, user_id) values (v_id, me);
  return v_id;
end $$;

create or replace function public.join_circle(p_circle uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Herds are invite only. A member can nominate you.';
end $$;

create or replace function public.find_my_circle()
returns uuid language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Herds are invite only now. Start your own, or get nominated by a member.';
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
    raise exception 'This herd is full right now.';
  end if;
  if (select count(*) from circle_members where user_id = me) >= 10 then
    raise exception 'You''re in 10 herds already. Leave one first.';
  end if;
  insert into circle_members (circle_id, user_id) values (c.id, me) on conflict do nothing;
  update circle_nominations set status = 'joined', decided_at = now() where id = n.id;
  perform notify(m.user_id, 'circle_joined', (select display_name from profiles where id = me) || ' joined ' || c.name || '.')
  from circle_members m where m.circle_id = c.id and m.user_id <> me;
end $$;

create or replace function public.nominate_to_circle(p_circle uuid, p_user uuid, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := require_tester();
  v_id uuid;
begin
  if not is_circle_member(p_circle, me) then raise exception 'Not in this herd.'; end if;
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

create or replace function public.lately(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with topic_score as (
    select topic_id, sum(w) as score from (
      select po.topic_id, 3 as w from posts po
       where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 2 from comments c join posts po on po.id = c.post_id
       where c.author_id = p_user and c.status = 'visible' and c.created_at > now() - interval '30 days'
      union all
      select po.topic_id, 1 from reactions r join posts po on po.id = r.post_id
       where r.user_id = p_user and r.created_at > now() - interval '30 days'
      union all
      select e.topic_id, 2 from event_rsvps r join events e on e.id = r.event_id
       where r.user_id = p_user and r.status = 'going' and e.topic_id is not null and r.created_at > now() - interval '30 days'
    ) x group by topic_id
  ),
  lines as (
    select 1 as ord, 'topic' as kind, 'Into ' || t.name || ' lately' as label, ts.score
      from topic_score ts join topics t on t.id = ts.topic_id
    union all
    select 2, 'event', 'Going to ' || e.title, 0
      from event_rsvps r join events e on e.id = r.event_id
     where r.user_id = p_user and r.status = 'going' and e.audience = 'public' and not is_quiet(p_user)
       and e.starts_at between now() and now() + interval '30 days'
    union all
    select 3, 'posts', 'Posted ' || count(*) || ' times this month', 0
      from posts po where po.author_id = p_user and po.status = 'visible' and po.created_at > now() - interval '30 days'
     having count(*) >= 2
    union all
    select 4, 'circles', 'In ' || count(*) || case when count(*) = 1 then ' herd' else ' herds' end, 0
      from circle_members cm where cm.user_id = p_user and not is_quiet(p_user)
     having count(*) >= 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'label', label) order by ord, score desc), '[]')
  from (select * from lines order by ord, score desc limit 5) l;
$$;

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
      when 'circle_invite'    then 'Herd invite'
      when 'circle_vote'      then 'New nomination'
      when 'circle_joined'    then 'New member'
      when 'warning'          then 'A note from Based'
      when 'venue'            then 'Your venue'
      when 'venue_bar'        then 'Venue access'
      when 'table_request'    then 'Table request'
      when 'table_reply'      then 'Your table'
      else 'Based' end,
    new.body,
    jsonb_build_object('kind', new.kind));
  return null;
end $$;
