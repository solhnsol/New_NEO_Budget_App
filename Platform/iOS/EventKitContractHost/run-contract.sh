#!/bin/zsh
# Builds the spike executable for the iOS simulator, wraps it in a minimal .app (SwiftPM does not bundle
# .iOSApplication on the command line), grants calendar access, launches it and prints the log.
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SIM=${SIM:-E72C623A-60D2-4052-B1D4-64A7E33E34AB}
BID=dev.onall.contracthost
DD=/private/tmp/claude-501/contract-dd
LOG=/tmp/claude-501/eventkit-contract.log
cd "$(dirname "$0")"
xcodebuild -scheme EventKitContractHost -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD build | grep -E "error|BUILD" || true
APP=$DD/ContractHost.app
rm -rf $APP && mkdir -p $APP
cp $DD/Build/Products/Debug-iphonesimulator/ContractHost $APP/ContractHost
cat > $APP/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BID</string>
<key>CFBundleExecutable</key><string>ContractHost</string>
<key>CFBundleName</key><string>ContractHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>17.0</string>
<key>UILaunchScreen</key><dict/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Runs the CalendarProvider contract against EventKit</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
xcrun simctl terminate $SIM $BID 2>/dev/null || true
xcrun simctl install $SIM $APP
xcrun simctl privacy $SIM reset calendar $BID
xcrun simctl privacy $SIM grant calendar $BID
rm -f $LOG
xcrun simctl launch $SIM $BID
for i in {1..60}; do grep -q '^exit$' $LOG 2>/dev/null && break; sleep 1; done
cat $LOG
