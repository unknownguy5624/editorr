# QuickCut (step 1)

Trim, speed, filters, text, music, export, AdMob (test ads).

## Get your APK (free)
1. Create a free GitHub account, then a NEW PUBLIC repository named quickcut.
2. Upload everything from this folder (lib, assets, tools, pubspec.yaml, .gitignore, .github).
   If the .github folder does not upload: Add file > Create new file, name it
   `.github/workflows/build.yml` (typing the slashes makes the folders) and paste in build.yml.
3. Open the Actions tab. "Build APK" runs automatically (5-10 min). If not, click it > Run workflow.
4. When it turns green, open the run, scroll to Artifacts, download `quickcut-apk`.
5. Unzip it. Install the `app-arm64-v8a-release.apk` on your phone (works on almost all modern phones).

## If the build fails
Open the failed run, copy the red error lines, and send them to Claude.

## Before publishing for real
- Ads are Google TEST ads. Create a free AdMob account and replace the IDs in
  `lib/services/ad_service.dart` and `tools/patch_android.py`.
- Play Store needs a signed app bundle (a later step).
