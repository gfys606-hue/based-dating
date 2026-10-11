"""Makes the website install cleanly to an iPhone (or Android) home screen.

Run from app/ after `flutter create` and `dart run flutter_launcher_icons`:
  - names it "Based" under the icon, not "based_dating"
  - full screen with the navy status bar, no Safari bars
  - the Based icon on the home screen
"""
import json
import re

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

html = re.sub(r"<title>.*?</title>", "<title>Based</title>", html, flags=re.S)
html = re.sub(r'<meta name="description" content="[^"]*">',
              '<meta name="description" content="Based. The door is not for everyone.">', html)

head = f"""
  <meta name="apple-mobile-web-app-capable" content="yes">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="Based">
  <meta name="theme-color" content="{NAVY}">
  <link rel="apple-touch-icon" href="icons/Icon-192.png">
  <link rel="apple-touch-icon" sizes="180x180" href="icons/Icon-192.png">
"""
html = html.replace("</head>", head + "</head>", 1)
open(INDEX, "w").write(html)

m = json.load(open(MANIFEST))
m.update({
    "name": "Based",
    "short_name": "Based",
    "description": "Based. The door is not for everyone.",
    "start_url": "/",
    "scope": "/",
    "display": "standalone",
    "background_color": NAVY,
    "theme_color": NAVY,
    "orientation": "portrait",
})
json.dump(m, open(MANIFEST, "w"), indent=2)
print("Home screen setup done")
