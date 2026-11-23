#!/bin/bash
# 와이파이 명당 찾기 빌드: Xcode 프로젝트 없이 swiftc 로 .app 을 만든다.
#   ./build.sh            빌드해서 ~/Applications 에 설치
#   ./build.sh --release  배포용 zip(build/WifiSpot-mac.zip, Apple 실리콘·인텔 모두)만 만든다
# 같은 서명을 계속 쓰고 싶으면 .local/signing.sh 에 BUNDLE_ID·SIGN_KC·SIGN_ID 를 둔다(깃에 안 올라감). 없으면 ad-hoc 서명.
set -euo pipefail
cd "$(dirname "$0")"
NAME="와이파이 명당 찾기"
RELEASE=0; [ "${1:-}" = "--release" ] && RELEASE=1
BUNDLE_ID="io.github.from5302-lab.wifispot"
SIGN_ID=""
if [ $RELEASE = 0 ] && [ -f .local/signing.sh ]; then . .local/signing.sh; fi
OUT="build/$NAME.app"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $ARCH-apple-macosx14.0 \
    -framework SwiftUI -framework CoreWLAN -framework Charts -framework Network -framework CoreLocation \
    Sources/*.swift -o "build/WifiSpot-$ARCH"
done
lipo -create build/WifiSpot-arm64 build/WifiSpot-x86_64 -output "$OUT/Contents/MacOS/WifiSpot"
rm -f build/WifiSpot-arm64 build/WifiSpot-x86_64
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>와이파이 명당 찾기</string>
  <key>CFBundleDisplayName</key><string>와이파이 명당 찾기</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>WifiSpot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocationWhenInUseUsageDescription</key><string>지금 연결된 와이파이 이름을 보여 주려고 써요</string>
  <key>NSLocationUsageDescription</key><string>지금 연결된 와이파이 이름을 보여 주려고 써요</string>
  <key>NSAppTransportSecurity</key><dict><key>NSExceptionDomains</key><dict><key>captive.apple.com</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict></dict>
</dict></plist>
PLIST
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$OUT/Contents/Resources/"
cp Resources/*.svg "$OUT/Contents/Resources/" 2>/dev/null || true
if [ -n "$SIGN_ID" ] && sign_unlock && codesign --force --deep --keychain "$SIGN_KC" -s "$SIGN_ID" "$OUT" >/dev/null 2>&1; then
  echo "서명: 고정 인증서"
else
  codesign --force --deep -s - "$OUT" >/dev/null; echo "서명: ad-hoc"
fi
if [ $RELEASE = 1 ]; then
  ditto -c -k --sequesterRsrc --keepParent "$OUT" build/WifiSpot-mac.zip
  echo "만듦: build/WifiSpot-mac.zip"; exit 0
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$NAME.app"
cp -R "$OUT" "$HOME/Applications/"
echo "만듦: $HOME/Applications/$NAME.app"
