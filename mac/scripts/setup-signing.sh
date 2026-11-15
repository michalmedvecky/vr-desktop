#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate on this Mac and stores it as
# GitHub Actions secrets of the repository, so CI signs every VRDesktop.app with the same key.
# macOS then keeps the Screen Recording / Accessibility permissions across app updates.
#
# Usage (in Terminal):  bash setup-signing.sh
# The private key never leaves this Mac except as an encrypted GitHub secret.
set -euo pipefail
REPO=michalmedvecky/vr-desktop
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR"

cat > cs.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VR Desktop Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF

PW=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 -config cs.cnf \
  -keyout key.pem -out cert.pem 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "VR Desktop Self-Signed" \
  -out sign.p12 -passout "pass:$PW"
base64 -i sign.p12 | tr -d '\n' > sign.b64

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh secret set MAC_SIGNING_P12 -R "$REPO" < sign.b64
  printf %s "$PW" | gh secret set MAC_SIGNING_PASSWORD -R "$REPO"
  echo "Hotovo: secrets jsou uložené v $REPO."
  exit 0
fi

URL="https://github.com/$REPO/settings/secrets/actions/new"
echo
echo "Nemáš přihlášené GitHub CLI (gh), uložíme secrets ručně, 2× vložit ze schránky:"
echo
pbcopy < sign.b64
echo "1) Ve schránce je hodnota pro MAC_SIGNING_P12."
echo "   Otevírám $URL"
echo "   Name: MAC_SIGNING_P12, Secret: Cmd+V, Add secret."
open "$URL"
read -r -p "   Hotovo? Stiskni Enter… " _
printf %s "$PW" | pbcopy
echo "2) Ve schránce je heslo pro MAC_SIGNING_PASSWORD."
open "$URL"
echo "   Name: MAC_SIGNING_PASSWORD, Secret: Cmd+V, Add secret."
read -r -p "   Hotovo? Stiskni Enter… " _
printf '' | pbcopy
echo "Hotovo. Napiš Claudovi, ať spustí nové sestavení."
