-- =====================================================================
-- Based Dating v1 — row-level security + function permissions
-- Principle: clients read/write only their own rows directly.
-- Everything about other people goes through the functions above,
-- which never expose location, scores, or scenario answers.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'profiles','user_scores','photos','topics','user_topics','likes','passes','matches',
    'messages','calls','engagement_events','notifications','impressions','blocks',
    'posts','comments','reactions','saves','poll_votes','topic_time',
    'reports','device_hashes','banned_devices'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- profiles: own row only
create policy "own profile read"   on public.profiles for select to authenticated using (id = auth.uid());
create policy "own profile insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "own profile update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- photos: own only (others via get_profile / get_match_batch)
create policy "own photos read"   on public.photos for select to authenticated using (user_id = auth.uid());
create policy "own photos insert" on public.photos for insert to authenticated with check (user_id = auth.uid());
create policy "own photos update" on public.photos for update to authenticated using (user_id = auth.uid());
create policy "own photos delete" on public.photos for delete to authenticated using (user_id = auth.uid());

-- topics: readable by all signed-in users
create policy "topics read" on public.topics for select to authenticated using (true);

create policy "own topics read"   on public.user_topics for select to authenticated using (user_id = auth.uid());
create policy "own topics insert" on public.user_topics for insert to authenticated with check (user_id = auth.uid());
create policy "own topics delete" on public.user_topics for delete to authenticated using (user_id = auth.uid());

-- likes / passes: read own outgoing (writes via like_user / pass_user)
create policy "own likes"  on public.likes  for select to authenticated using (from_user = auth.uid());
create policy "own passes" on public.passes for select to authenticated using (from_user = auth.uid());

-- matches / calls: participants read; writes via functions
create policy "match participants" on public.matches for select to authenticated
  using (auth.uid() in (user_a, user_b));
create policy "call participants" on public.calls for select to authenticated
  using (exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));

-- messages: participants read; blocked messages are only visible to the sender
create policy "read messages" on public.messages for select to authenticated using (
  exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b))
  and (status = 'sent' or sender_id = auth.uid()));
create policy "send messages" on public.messages for insert to authenticated with check (
  sender_id = auth.uid()
  and exists (select 1 from public.matches m where m.id = match_id and auth.uid() in (m.user_a, m.user_b)));

-- notifications: own
create policy "own notifications"        on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "own notifications update" on public.notifications for update to authenticated using (user_id = auth.uid());

-- blocks: own
create policy "own blocks" on public.blocks for select to authenticated using (blocker = auth.uid());

-- feed: posts are read through get_feed; you can read/insert/remove your own
create policy "own posts read"   on public.posts for select to authenticated using (author_id = auth.uid());
create policy "own posts insert" on public.posts for insert to authenticated with check (author_id = auth.uid());
create policy "own posts delete" on public.posts for delete to authenticated using (author_id = auth.uid());

create policy "comments read" on public.comments for select to authenticated using (
  (status = 'visible' or author_id = auth.uid())
  and exists (select 1 from public.posts p where p.id = post_id and p.status = 'visible'));
create policy "comments insert" on public.comments for insert to authenticated with check (author_id = auth.uid());
create policy "comments delete" on public.comments for delete to authenticated using (author_id = auth.uid());

create policy "own reactions" on public.reactions for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own saves"     on public.saves     for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own votes"     on public.poll_votes for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "own topic time" on public.topic_time for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- user_scores, engagement_events, impressions, reports, device tables:
-- RLS on with NO client policies => invisible to the app. Service role only.

-- ---------------------------------------------------------------------
-- Function permissions
-- ---------------------------------------------------------------------
-- Server-only functions (edge functions / cron using the service role)
do $$
declare f text;
begin
  foreach f in array array[
    'public.penalize(uuid,text,real,uuid)',
    'public.notify(uuid,text,text)',
    'public.refresh_photo_status(uuid)',
    'public.set_photo_review(uuid,boolean,boolean,text)',
    'public.set_selfie_verified(uuid,boolean)',
    'public.complete_call(uuid,text,int,uuid,text)',
    'public.mark_no_show(uuid,uuid,boolean)',
    'public.expire_matches()',
    'public.compute_engagement(uuid)',
    'public.recompute_scores()',
    'public.flag_comment_hostile(uuid)',
    'public.ban_user(uuid)',
    'public.effective_tier(uuid)',
    'public.photo_problem(uuid)',
    'public.make_icebreaker(uuid,uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- App-callable functions (signed-in users only)
do $$
declare f text;
begin
  foreach f in array array[
    'public.complete_onboarding()',
    'public.get_match_batch(int)',
    'public.like_user(uuid)',
    'public.pass_user(uuid)',
    'public.end_match(uuid,text)',
    'public.propose_call(uuid,timestamptz,text)',
    'public.accept_call(uuid)',
    'public.request_reschedule(uuid,timestamptz,text)',
    'public.get_feed(text,int,timestamptz,int)',
    'public.get_profile(uuid)',
    'public.get_my_matches()',
    'public.block_user(uuid)',
    'public.report_user(uuid,text,text,uuid)',
    'public.register_device(text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Storage buckets
--   photos  : readable by signed-in users, writable only in your own folder (<uid>/...)
--   selfies : private — only you and the server
--   media   : feed media, same rules as photos
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values
  ('photos','photos', false), ('selfies','selfies', false), ('media','media', false)
on conflict (id) do nothing;

create policy "photos read"  on storage.objects for select to authenticated
  using (bucket_id in ('photos','media'));
create policy "own uploads"  on storage.objects for insert to authenticated
  with check (bucket_id in ('photos','selfies','media') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own updates"  on storage.objects for update to authenticated
  using (bucket_id in ('photos','selfies','media') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own deletes"  on storage.objects for delete to authenticated
  using (bucket_id in ('photos','selfies','media') and (storage.foldername(name))[1] = auth.uid()::text);
create policy "own selfie read" on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and (storage.foldername(name))[1] = auth.uid()::text);

-- Realtime for chat + notifications
alter publication supabase_realtime add table public.messages, public.notifications, public.matches;
