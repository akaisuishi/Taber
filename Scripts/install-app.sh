#!/bin/zsh
set -euo pipefail

projectRoot="$(cd "$(dirname "$0")/.." && pwd)"
archivePath="$projectRoot/Build/Taber.zip"
stagingPath="$(mktemp -d "${TMPDIR%/}/taber-install.XXXXXX")"
sourceAppPath="$stagingPath/Taber.app"
destinationAppPath="/Applications/Taber.app"
trap 'rm -rf "$stagingPath"' EXIT

if [[ ! -f "$archivePath" ]]; then
  "$projectRoot/Scripts/build-app.sh"
fi

ditto -x -k --noqtn "$archivePath" "$stagingPath"
xattr -cr "$sourceAppPath"
codesign --verify --deep --strict "$sourceAppPath"

signatureDetails="$(codesign -dvv "$sourceAppPath" 2>&1)"
if [[ "$signatureDetails" == *"Signature=adhoc"* || "$signatureDetails" == *"TeamIdentifier=not set"* ]]; then
  cat >&2 <<'EOF'
Erro: Build/Taber.zip ainda contém uma build ad hoc antiga.

Configure seu Personal Team no Xcode, execute Scripts/build-app.sh e somente
depois instale a nova build. A versão em /Applications não foi alterada.
EOF
  exit 1
fi

pkill -x Taber 2>/dev/null || true
rm -rf "$destinationAppPath"
ditto --noextattr --noqtn "$sourceAppPath" "$destinationAppPath"
xattr -cr "$destinationAppPath"
codesign --verify --deep --strict "$destinationAppPath"

open "$destinationAppPath"
echo "Instalado: $destinationAppPath"
