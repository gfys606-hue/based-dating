/// The app's name and slogan, in one place. Renaming the app (e.g. to "The Door") is a change here:
/// every screen reads these, and the build reads appName for the phone's home-screen label and the website title.
const appName = 'Based';
const slogan = 'The door is not for everyone.';

/// Feature switches for whole modules. Flip back to `true` to bring the button(s) back —
/// none of the underlying screens, APIs, or Supabase tables are touched by these flags.
const kDatingEnabled = false; // "Ouch": Discover's dating pill, the You-screen toggle, Browse's Ouch filter
const kMarketEnabled = false; // the "Market" tab on the left rail
