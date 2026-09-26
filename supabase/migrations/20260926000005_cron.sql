-- =====================================================================
-- Scheduled jobs (Supabase: Database → Extensions → enable pg_cron first)
-- =====================================================================
create extension if not exists pg_cron;

select cron.schedule('expire-matches',   '5 * * * *',   $$select public.expire_matches()$$);   -- hourly
select cron.schedule('recompute-scores', '20 */6 * * *', $$select public.recompute_scores()$$); -- every 6 hours
