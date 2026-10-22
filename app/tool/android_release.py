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
    # make sure the keep rules below are used by the release build
    s = s.replace(
        'signingConfigs.getByName("release") else signingConfigs.getByName("debug")',
        'signingConfigs.getByName("release") else signingConfigs.getByName("debug")\n'
        '            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
        1,
    )

gradle.write_text(s)

# The name under the icon comes from lib/brand.dart
manifest = Path("android/app/src/main/AndroidManifest.xml")
if manifest.exists():
    name = re.search(r"appName = '([^']+)'", Path("lib/brand.dart").read_text()).group(1)
    manifest.write_text(re.sub(r'android:label="[^"]*"', f'android:label="{name}"', manifest.read_text(), count=1))

# Release builds are shrunk (R8). Keep the plugins' native classes, or a plugin can lose methods the app
# calls at startup (seen Oct 20 2026: shared_preferences NoSuchMethodError SharedPreferencesApiRegistrar.getAll,
# which left the app stuck on the launch logo). Flutter applies app/proguard-rules.pro automatically.
Path("android/app/proguard-rules.pro").write_text("""# Based: keep Flutter plugin classes intact in release builds
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class dev.flutter.pigeon.** { *; }
-keep class xyz.luan.audioplayers.** { *; }
-keep class com.llfbandit.record.** { *; }
-keep class com.baseflow.geolocator.** { *; }
-keep class io.flutter.plugins.firebase.** { *; }
-keep class io.livekit.** { *; }
-keep class org.webrtc.** { *; }
-dontwarn io.flutter.embedding.**
""")
print(f"Android release config ready: {APP_ID}")
