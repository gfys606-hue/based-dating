# Google Play launch kit

Everything Google Play asks for, ready to copy in.

## Already done in the code
- **App ID:** `com.basedsocial.app` (permanent after the first upload)
- **Release file:** every push to `main` builds `app-release.aab` (GitHub → Actions → latest run → Artifacts → `based-play-store-bundle`), once the two upload-key secrets are added
- **Version code** goes up automatically with each build
- **App icon** matches the site
- **Delete account** is in the app (You → Delete account) and on the web at https://based-social.com/delete-account.html
- **Privacy policy:** https://based-social.com/privacy.html
- **Report + block** are in chat and calls
- **18+:** enforced when a profile is created (birthdate check)

## One-time setup (you)
1. Add the GitHub secrets `ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD` (values are in the private key file you were given).
2. Run `supabase/migrations/20260927000007_delete_account.sql` in the Supabase SQL Editor.
3. Set up a real inbox for **support@based-social.com** (GoDaddy email forwarding to your Gmail works). Google and users will email it.
4. Create a **review account** for Google: Supabase → Authentication → Users → Add user → email `review@based-social.com`, set a password, tick *Auto Confirm User*. Log in once with it and finish onboarding (photos, interests) so reviewers see a working app.

## In the Play Console
1. Create a developer account ($25, ID verification).
2. **Create app:** name `Based`, app (not game), free.
3. **Setup → App signing:** use Google Play App Signing (default). Upload `app-release.aab` to the **Closed testing** track.
4. **Closed test:** add 12+ testers (their Gmail addresses), keep them opted in for 14 days straight, then apply for production.

## Store listing
- **App name:** Based
- **Short description (80 max):** Dating for people who actually show up. Match, call within 3 days, meet.
- **Full description:**

> Based is dating for people who actually show up.
>
> No endless swiping, no pen pals. When you match, you have three days to talk on a quick in-app call. Show up, and the match continues. Don't, and it's gone.
>
> • See the closest people first, matched by what you're actually into
> • Real photos only: every profile is checked to be the real person
> • No bios to perfect: your interests and activity speak for you
> • Contact info unlocks only after you've talked
> • Collecting matches without talking to anyone? You'll be shown less
> • Free. No premium tier. Nobody can pay to see better matches
>
> 18+ only.

- **Category:** Dating
- **Contact email:** support@based-social.com · **Website:** https://based-social.com
- **Graphics:** `icon-512.png`, `feature-graphic-1024x500.png` (in this folder), plus 2–8 phone screenshots (take them from the test app).

## App content answers
- **Privacy policy:** https://based-social.com/privacy.html
- **App access:** "All or some functionality is restricted" → give the review account email + password; note "Choose Log in → Log in with a password".
- **Ads:** No (change to Yes when ads are added)
- **Content rating (IARC):** category *Social / Communication*; users can interact and exchange messages: Yes; shares user location: Yes (approximate distance); no violence, sexual content, gambling or drugs in the app itself.
- **Target audience:** 18 and over only
- **Government / financial / health app:** No
- **Account deletion URL:** https://based-social.com/delete-account.html

## Data safety form
Data is **encrypted in transit**: Yes. Users **can request deletion**: Yes. Data is **not sold** and not shared with third parties (Supabase, AWS and Resend are service providers, which Google does not count as sharing).

| Data type | Collected | Why | Optional? |
|---|---|---|---|
| Name | Yes | App functionality | Required |
| Email address | Yes | Account management | Required |
| User IDs | Yes | App functionality, account management | Required |
| Sexual orientation (who you're seeking) | Yes | App functionality | Required |
| Other info (birthdate, gender) | Yes | App functionality | Required |
| Approximate + precise location | Yes | App functionality | Required |
| Photos | Yes | App functionality, fraud prevention/security | Required |
| Other in-app messages | Yes | App functionality | Required |
| Other user-generated content (posts, comments) | Yes | App functionality | Optional |
| App interactions (likes, matches, calls) | Yes | App functionality, fraud prevention/security | Required |
| Device or other IDs | Yes | Fraud prevention/security | Required |

## Before going public (not store paperwork, but reviewers will notice)
- **Calls aren't live yet.** The 3-day call rule is built, but the actual voice/video call (LiveKit) still needs to be plugged in. Launch production after that works; the closed test can start before.
- When calls are added, the app will also need microphone permission.
