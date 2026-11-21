#!/bin/bash
# 黑雷达 Studio · iOS —— 未签名 IPA 构建脚本
#
#   macOS（Xcode 15+）： ./build.sh
#   产物：build/BlackRadarStudio-0.1.0-unsigned.ipa（另存一份 build/SystemCheck.ipa 给 CI 用）
#   模拟器冒烟测试（默认开）：SIM=0 ./build.sh 可关掉
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/build}
NAME=BlackRadarStudio
VERSION=0.1.0
BUNDLE_ID=com.akwkw1.blackradarstudio

if [ -z "${SDK:-}" ] && command -v xcrun >/dev/null 2>&1; then
	SDK=$(xcrun --sdk iphoneos --show-sdk-path)
	SWIFTC=${SWIFTC:-$(xcrun --sdk iphoneos --find swiftc)}
fi
: "${SDK:?需要一个 iPhoneOS SDK（macOS 上 xcrun 会自己找）}"
SWIFTC=${SWIFTC:-swiftc}

rm -rf "$OUT/Payload" "$OUT/sim" "$OUT/$NAME-$VERSION-unsigned.ipa" "$OUT/SystemCheck.ipa"
mkdir -p "$OUT/Payload"
APP="$OUT/Payload/$NAME.app"
mkdir -p "$APP"

echo "== 编译设备版: $("$SWIFTC" --version 2>/dev/null | head -1)"
"$SWIFTC" -sdk "$SDK" -target arm64-apple-ios17.0 \
	-swift-version 5 -O -parse-as-library -module-name "$NAME" \
	-o "$APP/$NAME" "$HERE"/Sources/*.swift

cp "$HERE/Info.plist" "$APP/Info.plist"
python3 -I "$HERE/mkicon.py" "$APP"
printf 'APPL????' > "$APP/PkgInfo"

if command -v ldid >/dev/null 2>&1; then
	ldid -S "$APP/$NAME" && echo "== ldid 已做临时签名（Sideloadly/eSign 会重签）"
fi

echo "== 打包 IPA"
(cd "$OUT" && python3 -c "import shutil; shutil.make_archive('$NAME-$VERSION-unsigned','zip','.','Payload')")
mv "$OUT/$NAME-$VERSION-unsigned.zip" "$OUT/$NAME-$VERSION-unsigned.ipa"
cp "$OUT/$NAME-$VERSION-unsigned.ipa" "$OUT/SystemCheck.ipa"
ls -l "$OUT/$NAME-$VERSION-unsigned.ipa"

# ---------- 模拟器冒烟测试：装一遍、跑起来、截张图 ----------
if [ "${SIM:-1}" = "1" ] && command -v xcrun >/dev/null 2>&1 && command -v swiftc >/dev/null 2>&1; then
	SIMSDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)
	if [ -n "$SIMSDK" ]; then
		SIMAPP="$OUT/sim/$NAME.app"
		mkdir -p "$SIMAPP"
		echo "== 编译模拟器版"
		if "$SWIFTC" -sdk "$SIMSDK" -target arm64-apple-ios17.0-simulator \
			-swift-version 5 -Onone -parse-as-library -module-name "$NAME" \
			-o "$SIMAPP/$NAME" "$HERE"/Sources/*.swift; then
			cp "$HERE/Info.plist" "$SIMAPP/Info.plist"
			python3 -I "$HERE/mkicon.py" "$SIMAPP" >/dev/null
			UDID=$(python3 - <<'PY'
import json, subprocess
out = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                     capture_output=True, text=True).stdout
try:
    data = json.loads(out)
except Exception:
    print("")
    raise SystemExit
best = ""
for runtime, devs in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for d in devs:
        if d.get("isAvailable") and str(d.get("name", "")).startswith("iPhone"):
            best = d.get("udid", "")
print(best)
PY
)
			if [ -n "$UDID" ]; then
				echo "== 模拟器 $UDID"
				xcrun simctl boot "$UDID" 2>/dev/null || true
				xcrun simctl bootstatus "$UDID" -b 2>/dev/null || true
				xcrun simctl install "$UDID" "$SIMAPP" || true
				xcrun simctl launch "$UDID" "$BUNDLE_ID" || true
				sleep 9
				xcrun simctl io "$UDID" screenshot "$OUT/screenshot.png" || true
				if [ -f "$OUT/screenshot.png" ]; then
					echo "== 截图 $OUT/screenshot.png ($(wc -c < "$OUT/screenshot.png") bytes)"
					echo "SCREENSHOT_BASE64_BEGIN"
					python3 -c "import base64,sys;print(base64.b64encode(open(sys.argv[1],'rb').read()).decode())" "$OUT/screenshot.png"
					echo "SCREENSHOT_BASE64_END"
				fi
				echo "== 最近崩溃报告（如果有）"
				ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | head -3 || echo "无"
			else
				echo "== 没有可用的 iPhone 模拟器，跳过冒烟测试"
			fi
		else
			echo "!! 模拟器编译失败，跳过冒烟测试"
		fi
	fi
fi

echo "完成：$OUT/$NAME-$VERSION-unsigned.ipa"
