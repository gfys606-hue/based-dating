"""Makes the web app (based-social.com/app/) install cleanly to an iPhone (or Android) home screen.

Run from app/ after `flutter create` and `dart run flutter_launcher_icons`:
  - names it "Based" under the icon, not "based_dating"
  - full screen with the navy status bar, no Safari bars
  - the Based icon on the home screen
"""
import json
import re

# The name and slogan come from lib/brand.dart, the one place the app's name lives
_brand = open("lib/brand.dart").read()
NAME = re.search(r"appName = '([^']+)'", _brand).group(1)
SLOGAN = re.search(r"slogan = '([^']+)'", _brand).group(1)

INDEX = "web/index.html"
MANIFEST = "web/manifest.json"
NAVY = "#110B07"  # dark walnut (name kept for history)

html = open(INDEX).read()

# Drop whatever flutter create put in, then add ours once
for pat in [
    r'\s*<meta name="apple-mobile-web-app-capable"[^>]*>',
    r'\s*<meta name="mobile-web-app-capable"[^>]*>',
    r'\s*<meta name="apple-mobile-web-app-status-bar-style"[^>]*>',
    r'\s*<meta name="apple-mobile-web-app-title"[^>]*>',
    r'\s*<meta name="theme-color"[^>]*>',
    r'\s*<link rel="apple-touch-icon"[^>]*>',
]:
    html = re.sub(pat, "", html)

html = re.sub(r"<title>.*?</title>", f"<title>{NAME} · Open the app</title>", html, flags=re.S)
html = re.sub(r'<meta name="description" content="[^"]*">',
              f'<meta name="description" content="{NAME}. {SLOGAN}">', html)

head = f"""
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="{NAME}">
  <meta name="theme-color" content="{NAVY}">
  <link rel="apple-touch-icon" href="icons/Icon-192.png">
  <link rel="apple-touch-icon" sizes="180x180" href="icons/Icon-192.png">
  <link rel="canonical" href="https://based-social.com/app/">
  <meta property="og:title" content="{NAME} · {SLOGAN}">
  <meta property="og:description" content="The members-only social network for real people.">
  <meta property="og:image" content="https://based-social.com/og.png">
"""
html = html.replace("</head>", head + "</head>", 1)
open(INDEX, "w").write(html)

m = json.load(open(MANIFEST))
m.update({
    "name": NAME,
    "short_name": NAME,
    "description": f"{NAME}. {SLOGAN}",
    "start_url": "/app/",
    "scope": "/app/",
    "display": "standalone",
    "background_color": NAVY,
    "theme_color": NAVY,
    "orientation": "portrait",
})
json.dump(m, open(MANIFEST, "w"), indent=2)
print("Home screen setup done")
