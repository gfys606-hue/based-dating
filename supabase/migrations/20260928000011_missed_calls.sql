-- Missed calls: close out calls that nobody (or only one person) joined.
-- Runs every 10 minutes. A call counts as missed 30 minutes after its start time.
--   * one person joined, the other didn't -> the no-show takes the penalty; the other is told
--     they can end the match with no penalty or give them another shot
--   * nobody joined                     -> both get a light penalty and a reminder; the match
--                                          stays open until its normal deadline
--   * a proposal nobody accepted in time is quietly cancelled
-- Either way the call is closed, so "Propose a call" shows up again in the chat.

create or replace function public.sweep_missed_calls()
returns int language plpgsql security definer set search_path = public as $$
declare
  c calls;
  m matches;
  n int := 0;
  u uuid;
begin
  -- proposals that were never accepted before their time passed
  update calls set status = 'cancelled'
  where status = 'proposed' and scheduled_for < now() - interval '30 minutes';

  for c in select * from calls
           where status = 'accepted' and both_joined_at is null
             and scheduled_for < now() - interval '30 minutes'
           for update skip locked loop
    select * into m from matches where id = c.match_id;

    if cardinality(c.joined_users) = 1 then
      u := case when c.joined_users[1] = m.user_a then m.user_b else m.user_a end;
      perform mark_no_show(c.id, u, false);
    else
      update calls set status = 'missed' where id = c.id;
      if m.status = 'active' then
        perform penalize(m.user_a, 'no_show', 0.05, m.id);
        perform penalize(m.user_b, 'no_show', 0.05, m.id);
        perform notify(m.user_a, 'call_missed', 'Your call was missed. Pick a new time before the deadline.');
        perform notify(m.user_b, 'call_missed', 'Your call was missed. Pick a new time before the deadline.');
      end if;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.sweep_missed_calls() from public, anon, authenticated;

select cron.schedule('sweep-missed-calls', '*/10 * * * *', $$select public.sweep_missed_calls()$$);
