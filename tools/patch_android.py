import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])

# ---- AndroidManifest.xml ----
manifest = root / "android/app/src/main/AndroidManifest.xml"
text = manifest.read_text()

perms = (
    "    <uses-permission android:name=\"android.permission.INTERNET\"/>\n"
    "    <uses-permission android:name=\"android.permission.ACCESS_NETWORK_STATE\"/>\n"
    "    <uses-permission android:name=\"android.permission.WRITE_EXTERNAL_STORAGE\" "
    "android:maxSdkVersion=\"28\"/>\n"
)
text = text.replace("<application", perms + "    <application", 1)

# Google TEST AdMob app id. Replace with your own before publishing.
meta = (
    "        <meta-data\n"
    "            android:name=\"com.google.android.gms.ads.APPLICATION_ID\"\n"
    "            android:value=\"ca-app-pub-3940256099942544~3347511713\"/>\n"
)
text = text.replace("</application>", meta + "    </application>", 1)
text = re.sub(r"android:label=\"[^\"]*\"", "android:label=\"QuickCut\"", text, count=1)
manifest.write_text(text)

# ---- minSdk 24 (needed by FFmpeg) ----
for name in ("build.gradle.kts", "build.gradle"):
    f = root / "android/app" / name
    if f.exists():
        g = f.read_text()
        g = g.replace("minSdk = flutter.minSdkVersion", "minSdk = 24")
        g = g.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion 24")
        f.write_text(g)

print("Android config patched")
