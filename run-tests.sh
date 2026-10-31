#!/bin/zsh
# Logic self-tests. XCTest/Swift Testing need Xcode plugins, so compile the app sources (minus @main) with Tests/main.swift.
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
OUT=$(mktemp -d)
SDKROOT=$SDK swiftc -o $OUT/selftest -lsqlite3 Tests/main.swift $(ls Sources/DevHub/*.swift | grep -v DevHubApp.swift)
$OUT/selftest
rm -rf $OUT
