"""Prepares the generated Android project for Google Play.

Run from app/ after `flutter create`:
  - sets the permanent Play Store application ID
  - signs release builds with the upload key when ANDROID_KEYSTORE_PATH is set
    (otherwise release builds fall back to debug signing, which Play rejects)
"""
import re
import sys
from pathlib import Path

APP_ID = "com.basedsocial.app"  # Permanent once published on Google Play.

gradle = Path("android/app/build.gradle.kts")
if not gradle.exists():
    sys.exit("android/app/build.gradle.kts not found - run flutter create first")
s = gradle.read_text()

s, n = re.subn(r'applicationId = "[^"]*"', f'applicationId = "{APP_ID}"', s)
if n != 1:
    sys.exit("could not set applicationId")

if 'create("release")' not in s:
    signing = '''    signingConfigs {
        create("release") {
            val ks = System.getenv("ANDROID_KEYSTORE_PATH")
            if (ks != null) {
                storeFile = file(ks)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: "upload"
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {'''
    s, n = re.subn(r"    buildTypes \{", signing, s, count=1)
    if n != 1:
        sys.exit("could not add signingConfigs")
    s, n = re.subn(
        r'signingConfig = signingConfigs\.getByName\("debug"\)',
        'signingConfig = if (System.getenv("ANDROID_KEYSTORE_PATH") != null) '
        'signingConfigs.getByName("release") else signingConfigs.getByName("debug")',
        s,
        count=1,
    )
    if n != 1:
        sys.exit("could not set release signing")

gradle.write_text(s)
print(f"Android release config ready: {APP_ID}")
