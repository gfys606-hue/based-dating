# Based Dating — v1 foundation

Real people, real conversations. This is the working foundation: the full database with every rule we designed, two server functions, and a Flutter app skeleton wired to it.

## What's in here

```
supabase/
  migrations/
    ..._1_schema.sql        tables: profiles, photos, interests, likes, matches, messages, calls, …
    ..._2_rules.sql         distance-block matching, hidden score + nudges + throttle, 3-day call window,
                            5-min minimum, 2 shared reschedules, contact filter + phone unlock, photo pause
    ..._3_feed_safety.sql   interest feed, profiles-as-activity, reports, blocks, device bans
    ..._4_security.sql      row-level security, function permissions, storage buckets
    ..._5_cron.sql          hourly match expiry + score recompute every 6 h
    ..._6_home_talk.sql     extra match data for the Home and Talk screens (already applied)
  functions/
    photo-check/            AI selfie + photo checks (AWS Rekognition)
    call-webhook/           applies call rules when a call ends
  tests/                    local test suite (all rules pass)
app/                        Flutter app (iOS + Android)
waitlist/index.html         pre-launch waitlist site (sign-ups go into the `waitlist` table)
```

## Where each rule lives

| Rule | Where |
|---|---|
| Distance blocks 10 → 15 → 25 → 50 km…, interest-first in 10 km, closest-first after | `get_match_batch` |
| Invisible desirability pull (no scores ever shown) | `get_match_batch`, `recompute_scores` |
| Hidden engagement score, 2 nudges, then gradual invisibility, recovery | `compute_engagement`, `recompute_scores` |
| "Not feeling it" never penalized | `end_match` |
| 3-day window, 5-min minimum, 2 shared reschedules, early hang-up uses one | `propose_call`, `request_reschedule`, `complete_call` |
| No-shows, expiry penalizes the unresponsive side | `mark_no_show`, `expire_matches` |
| No contact info until video call + 1 message each; links/handles always blocked | `detect_contact`, message triggers |
| Photos 1–3 clear face, 4–6 looser but must be you; otherwise paused | `set_photo_review`, `refresh_photo_status` |
| Feed open to all, distance slider, like counts only for author | `get_feed` |
| 3+ reporters → auto-suspend; underage/threats prioritized; device bans | `report_user`, `ban_user`, `register_device` |

## Setup

### 1. Supabase (≈10 min)
1. Create a project at supabase.com (Canada Central region).
2. **Database → Extensions:** enable `pg_cron`.
3. **SQL Editor:** run the migration files in order (1 → 5). Or with the CLI: `supabase link` then `supabase db push`.
4. **Sign-in:** the app uses email + 6-digit code (free, built in). In **Authentication → Email Templates → Magic Link**, add `{{ .Token }}` to the email so it shows the code. Before real launch, add your own email sender under **Authentication → SMTP** (e.g. Resend) — Supabase's built-in sender only allows a few emails per hour. Phone sign-in via Twilio can be added later.
5. Deploy functions:
   ```
   supabase functions deploy photo-check
   supabase functions deploy call-webhook --no-verify-jwt
   supabase secrets set AWS_REGION=ca-central-1 AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… CALL_WEBHOOK_SECRET=…
   ```

### 2. Flutter app
1. Install Flutter: https://docs.flutter.dev/get-started/install
2. In `app/`, run `flutter create . --org com.based --project-name based_dating` (adds iOS/Android folders), then `flutter pub get`.
3. Add camera + location permissions (iOS `Info.plist`: `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`, `NSLocationWhenInUseUsageDescription`; Android manifest: `ACCESS_FINE_LOCATION`, `CAMERA`).
4. Run:
   ```
   flutter run --dart-define=SUPABASE_URL=https://YOUR.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
   ```

### 3. Run the backend tests locally (optional)
Needs a local Postgres 16 on port 5433: `cd supabase/tests && ./run.sh`

## Based Social modules (testers only)
Circles, Search, Events and Market live in `supabase/migrations/20260927000009_social_modules.sql` and `app/lib/screens/` (`circles_screen`, `search_screen`, `events_screen`, `market_screen`). Testers get module tabs down the left side; everyone else sees only Dating.
1. Run migration `20260927000009_social_modules.sql` in the Supabase SQL Editor.
2. Make someone a tester: Table Editor → `profiles` → set `is_tester` to `true` (users can't set this themselves).
3. Test app for Android: https://based-social.com/test (rebuilt on every push).

## Not built yet (next steps)
1. **Real calls:** built with LiveKit. Add the keys and deploy (see `play-store/PLAY_STORE.md` → Turning on calls).
2. **Push notifications:** send rows from `notifications` via Firebase Cloud Messaging.
3. **AI moderation for messages/comments** (scams, hostility) → `flag_comment_hostile`.
4. **Moderator dashboard** for reports and pending photos 4–6.
5. **Media posts and polls** in the feed UI (the database already supports them).
6. Terms of service + privacy policy (PIPEDA), reviewed by a lawyer.

Later phases: groups/events (v1.1), ads → fair boosts → ad-free support plan.

## Waitlist site
`waitlist/index.html` is a single self-contained page. Host it anywhere static:
- **Netlify Drop:** go to app.netlify.com/drop and drag the `waitlist` folder in (free account keeps it live), then add your domain.
- Add `?ref=tiktok`, `?ref=instagram` etc. to links you share — the source is saved with each sign-up.
- See sign-ups: Supabase → Table Editor → `waitlist`. Per city: `select city, gender, count(*) from waitlist group by 1,2 order by 3 desc;`

## App layout (v1, dating only)
Four fixed destinations in a floating menu. Future modules (search, shop, groups) slot into these same four, so nothing gets redesigned:
- **Home · Your day** (`home_screen.dart`): next call, replies waiting on you, deadlines, new people, a post nearby.
- **Discover** (`discover_screen.dart`): People as Cards or on the Radar (10/15/25/50 km rings), or Posts (`feed_screen.dart`).
- **Talk** (`talk_screen.dart`): "Needs a call" timer tiles, then all conversations.
- **You** (`you_screen.dart`): profile and account.
Shared design pieces live in `lib/theme.dart`, `lib/widgets/ui.dart` and `lib/widgets/nav_bar.dart`. New modules must reuse them.
