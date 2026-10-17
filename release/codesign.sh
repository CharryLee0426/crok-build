#!/bin/bash
# Signs crok and Crok Desktop with a certificate that stays the same from build to build.
#
#   release/codesign.sh [codesign options] PATH...   Sign (codesign --force --sign, plus the options).
#   release/codesign.sh --certificate                Print the identity's certificate (PEM).
#
# macOS keeps a privacy permission (Screen Recording, Accessibility, the microphone, ...) for the
# code requirement of the signature it was given to. An ad hoc signature's requirement is that
# one build's hash, so every rebuild and every update lost them. Signed here, the requirement is
# `identifier "<id>" and certificate leaf = H"<certificate>"`, which every later build signed by
# the same certificate meets, so the permissions carry over to it.
#
# The identity, "Crok Code Signing", is self-signed and made on first use in a keychain of its own
# in CROK_CODESIGN_DIR (default ~/.crok-codesign), beside the password that unlocks it. Copy that
# folder to sign on another Mac with the same certificate: a new folder makes a new certificate,
# and macOS then asks for every permission once more. release/publish.sh only publishes builds
# signed by the certificate in release/crok-codesign.pem.
#
# Environment:
#   SIGN_IDENTITY       Sign with this identity instead: a Developer ID name, or - for ad hoc.
#   CROK_CODESIGN_DIR   The folder holding the keychain.
set -euo pipefail

name="Crok Code Signing"
dir="${CROK_CODESIGN_DIR:-$HOME/.crok-codesign}"
keychain="$dir/crok-codesign.keychain-db"
password_file="$dir/password"
staging=""

fail() { printf 'codesign: %s\n' "$*" >&2; exit 1; }

# Runs a step, showing its output only when it fails.
quietly() {
    local output
    if ! output="$("$@" 2>&1)"; then fail "$1 failed: $output"; fi
}

# Makes the identity in a folder of its own and renames it into place, so an interrupted run
# leaves nothing half made.
create_identity() {
    local parent password
    parent="$(/usr/bin/dirname "$dir")"
    /bin/mkdir -p "$parent"
    staging="$(/usr/bin/mktemp -d "$parent/.crok-codesign.XXXXXX")"
    trap '/bin/rm -rf "$staging"' EXIT
    /bin/chmod 700 "$staging"
    (umask 077 && /usr/bin/openssl rand -hex 32 > "$staging/password")
    password="$(/bin/cat "$staging/password")"
    /bin/cat > "$staging/certificate.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = $name
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    # The system's LibreSSL writes a PKCS#12 file that `security import` reads; OpenSSL 3's default does not.
    (umask 077 && quietly /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 10950 -config "$staging/certificate.cnf" \
        -keyout "$staging/key.pem" -out "$staging/certificate.pem")
    (umask 077 && quietly /usr/bin/openssl pkcs12 -export -name "$name" -inkey "$staging/key.pem" -in "$staging/certificate.pem" \
        -passout file:"$staging/password" -out "$staging/identity.p12")
    quietly /usr/bin/security create-keychain -p "$password" "$staging/crok-codesign.keychain-db"
    # No timeout and no lock on sleep; every signing unlocks it anyway.
    quietly /usr/bin/security set-keychain-settings "$staging/crok-codesign.keychain-db"
    quietly /usr/bin/security import "$staging/identity.p12" -k "$staging/crok-codesign.keychain-db" -P "$password" -T /usr/bin/codesign
    # Lets codesign use the key without asking.
    quietly /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$staging/crok-codesign.keychain-db"
    /bin/rm -f "$staging/key.pem" "$staging/identity.p12" "$staging/certificate.cnf"
    [[ ! -e "$dir" ]] || fail "$dir appeared while the identity was being made; run again"
    /bin/mv "$staging" "$dir"
    trap - EXIT
    printf 'Made the "%s" identity in %s. Keep that folder: it signs every build macOS should treat as the same app.\n' "$name" "$dir" >&2
}

# The identity's SHA-1, with its keychain unlocked; nothing when the folder holds none.
identity() {
    [[ -f "$keychain" && -f "$password_file" ]] || return 0
    quietly /usr/bin/security unlock-keychain -p "$(/bin/cat "$password_file")" "$keychain"
    /usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/awk -v name="\"$name\"" 'index($0, name) { print $2; exit }'
}

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail "code signing needs macOS"

if [[ "${1:-}" == --certificate ]]; then
    [[ -f "$keychain" ]] || fail "no \"$name\" identity in $dir"
    /usr/bin/security find-certificate -p -c "$name" "$keychain"
    exit 0
fi
[[ $# -gt 0 ]] || fail "usage: release/codesign.sh [codesign options] PATH..."

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    exec /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$@"
fi
if [[ ! -e "$dir" ]]; then
    create_identity
fi
hash="$(identity)"
[[ -n "$hash" ]] || fail "$dir holds no \"$name\" identity; move the folder aside and run again to make a new one"
exec /usr/bin/codesign --force --sign "$hash" --keychain "$keychain" "$@"
