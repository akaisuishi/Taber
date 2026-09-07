#!/bin/zsh
set -euo pipefail

projectRoot="$(cd "$(dirname "$0")/.." && pwd)"
derivedDataPath="$(mktemp -d "${TMPDIR%/}/taber-build.XXXXXX")"
builtAppPath="$derivedDataPath/Build/Products/Release/Taber.app"
verificationPath="$derivedDataPath/Verification"
finalArchivePath="$projectRoot/Build/Taber.zip"
legacyAppPath="$projectRoot/Build/Taber.app"
signingIdentity="${TABER_CODE_SIGN_IDENTITY:-}"
trap 'rm -rf "$derivedDataPath"' EXIT

if [[ -z "$signingIdentity" ]]; then
  signingIdentity="$(security find-identity -v -p codesigning | awk -F'"' '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi

if [[ -z "$signingIdentity" ]]; then
  cat >&2 <<'EOF'
Erro: nenhuma identidade estável de assinatura foi encontrada.

O Taber não gera mais builds ad hoc instaláveis, pois elas fazem o macOS
esquecer a permissão de Acessibilidade a cada recompilação.

No Xcode, abra Settings > Accounts, adicione seu Apple ID e selecione seu
Personal Team em Signing & Capabilities do target Taber.
EOF
  exit 1
fi

cd "$projectRoot"
xcodebuild \
  -project Taber.xcodeproj \
  -scheme Taber \
  -configuration Release \
  -derivedDataPath "$derivedDataPath" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -quiet \
  build

mkdir -p "$projectRoot/Build"
xattr -cr "$builtAppPath"
codesign --force --deep --sign "$signingIdentity" --identifier com.taber.app "$builtAppPath" >/dev/null
codesign --verify --deep --strict "$builtAppPath"
lipo "$builtAppPath/Contents/MacOS/Taber" -verify_arch arm64 x86_64

# Um .app armazenado diretamente no iCloud Drive recebe atributos FileProvider
# que invalidam a verificação estrita do codesign. O produto distribuível fica
# arquivado e é validado novamente após uma extração limpa.
rm -rf "$legacyAppPath"
rm -f "$finalArchivePath"
ditto -c -k --norsrc --keepParent "$builtAppPath" "$finalArchivePath"

mkdir -p "$verificationPath"
ditto -x -k --noqtn "$finalArchivePath" "$verificationPath"
xattr -cr "$verificationPath/Taber.app"
codesign --verify --deep --strict "$verificationPath/Taber.app"

echo "Criado: $finalArchivePath"
echo "Assinado por: $signingIdentity"
