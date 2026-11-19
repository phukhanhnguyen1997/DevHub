#!/bin/zsh
# Builds DevHub.app with Command Line Tools only (no Xcode needed).
# SDK 26.0 is pinned because the newer SDKs need Xcode's SwiftUIMacros plugin.
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[ -d "$SDK" ] || SDK=$(xcrun --show-sdk-path)
SDKROOT=$SDK swift build -c release
APP=DevHub.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp .build/release/DevHub $APP/Contents/MacOS/DevHub
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DevHub</string>
<key>CFBundleIdentifier</key><string>local.devhub</string>
<key>CFBundleExecutable</key><string>DevHub</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - $APP
echo "Built $PWD/$APP"
