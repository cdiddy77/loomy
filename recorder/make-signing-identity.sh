#!/bin/sh
# Makes a self-signed code signing certificate for Loomy Recorder, in a separate keychain file.
# With this certificate, macOS keeps the camera, microphone, and screen permissions after a new build.
# The script does not change the login keychain. Run it one time:
#   sh recorder/make-signing-identity.sh
# To remove the certificate, delete the keychain file and the password file that the script names.
set -eu

NAME="Loomy Recorder Local"
KEYCHAIN="$HOME/Library/Keychains/loomy-signing.keychain-db"
SECRET="$HOME/.config/loomy/signing-keychain-password"

if [ -f "$KEYCHAIN" ]; then
  echo "The keychain exists: $KEYCHAIN"
  exit 0
fi

umask 077
mkdir -p "$(dirname "$SECRET")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

openssl rand -hex 24 >"$SECRET"
PASSWORD="$(cat "$SECRET")"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# The security tool reads only the old PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
echo "The signing identity \"$NAME\" is in $KEYCHAIN."
echo "The keychain password is in $SECRET."
