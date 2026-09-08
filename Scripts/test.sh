#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
testRun="$(mktemp -d /tmp/taber-tests.XXXXXX)"
print "Evidence directory: $testRun"
mkdir -p Build/Validation
resultPath="$PWD/Build/Validation/$(date +%Y%m%d-%H%M%S).xcresult"
xcrun swiftc -module-cache-path "$testRun/cache" Sources/Taber/Services/WindowMatchingPolicy.swift Scripts/RegressionChecks/main.swift -o "$testRun/regressions"
"$testRun/regressions"
xcrun swiftc -module-cache-path "$testRun/cache" Sources/Taber/Services/WindowEligibilityPolicy.swift Scripts/WindowEligibilityCheck/main.swift -o "$testRun/window-eligibility-check"
"$testRun/window-eligibility-check" --self-test
selection=(-skip-testing:TaberUITests/LiveHIDIntegrationTests)
if [[ "${1:-}" == "--logic-only" ]]; then
    selection=(-only-testing:TaberTests)
elif [[ "${1:-}" == "--live-hid" ]]; then
    selection=(-only-testing:TaberUITests/LiveHIDIntegrationTests)
fi
xcodebuild -quiet -project Taber.xcodeproj -scheme Taber -configuration Debug \
    -destination 'platform=macOS' -parallel-testing-enabled NO \
    -derivedDataPath "$testRun/build" -resultBundlePath "$resultPath" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual "${selection[@]}" test
