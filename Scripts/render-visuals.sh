#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
sources=(Sources/Taber/**/*.swift)
sources=("${(@)sources:#Sources/Taber/TaberApp.swift}")
visualBuild="$(mktemp -d /tmp/taber-visual-build.XXXXXX)"
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$visualBuild/cache" "${sources[@]}" Scripts/VisualChecks/main.swift -o "$visualBuild/render"
"$visualBuild/render" "${1:-/tmp/taber-visuals}"
