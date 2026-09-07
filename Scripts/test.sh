#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
testRun="$(mktemp -d /tmp/taber-tests.XXXXXX)"
print "Evidence directory: $testRun"
xcrun swiftc -module-cache-path "$testRun/cache" Sources/Taber/Services/WindowMatchingPolicy.swift Scripts/RegressionChecks/main.swift -o "$testRun/regressions"
"$testRun/regressions"
selection=()
if [[ "${1:-}" == "--logic-only" ]]; then
    selection=(-only-testing:TaberTests)
fi
xcodebuild -quiet -project Taber.xcodeproj -scheme Taber -configuration Debug \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath "$testRun/build" -resultBundlePath "$testRun/Results.xcresult" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual "${selection[@]}" test
