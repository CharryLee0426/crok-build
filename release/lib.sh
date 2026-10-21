# shellcheck shell=bash
# Shared by release/publish.sh and the release workflow (.github/workflows/release.yml): the names of a
# release's files and the checks every build in a release must pass. Source it; it only defines functions.
#
# A script may define fail() before sourcing this; otherwise a failed check prints "release: <why>" (an
# error annotation inside GitHub Actions) and exits.

release_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -F fail >/dev/null; then
    fail() {
        if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
            printf '::error::%s\n' "$*"
        else
            printf 'release: %s\n' "$*" >&2
        fi
        exit 1
    }
fi

# The files of release VERSION that the release workflow publishes, beside SHA256SUMS.txt and its signature.
# Releases are for Apple silicon Macs. `crok upgrade` looks the first three up by these names
# (crates/codegen/crok-upgrade/src/assets.rs).
release_dmg() { printf 'Crok-Desktop-%s-arm64-macOS%s-SDK.dmg\n' "$1" "$2"; } # VERSION SDK (26 or 15)
release_tarball() { printf 'crok-%s-aarch64-apple-darwin.tar.gz\n' "$1"; }
release_ios_ipa() { printf 'Crok-iOS-%s-unsigned.ipa\n' "$1"; }
release_ios_simulator() { printf 'Crok-iOS-%s-Simulator.zip\n' "$1"; }
release_android_apk() { printf 'Crok-Android-%s.apk\n' "$1"; }
release_files() {
    release_dmg "$1" 26
    release_dmg "$1" 15
    release_tarball "$1"
    release_ios_ipa "$1"
    release_ios_simulator "$1"
    release_android_apk "$1"
}

# The SHA-1 of the PEM certificate on stdin, the form codesign's `certificate leaf = H"…"` takes.
fingerprint() { /usr/bin/openssl x509 -noout -fingerprint -sha1 | cut -d = -f 2 | tr -d : | tr '[:upper:]' '[:lower:]'; }

# The certificate every release is signed by (release/crok-codesign.pem).
pinned_signer() { fingerprint < "$release_lib_dir/crok-codesign.pem"; }

check_signer() {
    codesign --verify --strict -R="certificate leaf = H\"$(pinned_signer)\"" "$1" 2>/dev/null \
        || fail "$1 is not signed by the certificate in release/crok-codesign.pem"
}

# The macOS SDK a Mach-O file was linked against (its LC_BUILD_VERSION), such as 26.2.
linked_sdk() { otool -l "$1" | awk '/LC_BUILD_VERSION/ { f = 1 } f && /sdk/ && !done { print $2; done = 1 }'; }

# Fails unless EXECUTABLE, the app of the macOS SDK image (26 or 15), was linked against that SDK. The
# macOS 26 image is the one for macOS 26 and later, so a later SDK does too.
check_linked_sdk() {
    local linked
    linked="$(linked_sdk "$2")"
    case "$1:$linked" in
        26:26* | 26:27* | 26:28*) ;;
        15:15*) ;;
        *) fail "the macOS $1 image was linked against SDK $linked" ;;
    esac
}

# A field of `crok version --json`: release (VERSION when it was built), currentVersion ("1.0.45 (af1b3e395f68)").
crok_version_field() {
    "$1" version --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$2"
}

# Every crok in a release has the Agent Observability destination built in from an env file like this one.
check_agento11y_env() {
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?AGENTO11Y_ENDPOINT=.' "$1" 2>/dev/null \
        || fail "no Agent Observability destination to build in: $1 is missing or sets no AGENTO11Y_ENDPOINT (crates/codegen/xai-grok-agento11y/setup.sh writes it; CROK_AGENTO11Y_BUILTIN_ENV names another)"
}

# The endpoint host a crok reports to with nothing set up; empty for a build without one.
built_destination() { crok_version_field "$1" agentObservability; }

check_destination() {
    local host
    host="$(built_destination "$1")"
    [[ -n "$host" ]] || fail "$1 has no Agent Observability destination built in"
    printf '%s reports to %s\n' "$1" "$host"
}

# Every crok in a release signs in to the production relay, never the dev one test builds use.
check_relay() {
    local relay
    relay="$("$1" version --json | /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin).get("remote") or {}; print(r.get("env",""), r.get("url",""))')"
    [[ "$relay" == "prod "* ]] || fail "$1 signs in to the relay '$relay', not production (relay/environments/prod.env)"
    printf '%s signs in to %s\n' "$1" "${relay#prod }"
}

# A setting of the production relay (relay/environments/prod.env), such as CONVEX_URL.
prod_relay() { sed -n "s/^$1=//p" "$release_lib_dir/../relay/environments/prod.env" | tail -n 1; }

# The commit tag TAG names on origin (an annotated tag peeled to its commit); nothing when there is no such tag.
remote_tag_commit() {
    git ls-remote origin "refs/tags/$1" "refs/tags/$1^{}" \
        | awk '$2 ~ /\^\{\}$/ { peeled = $1; next } { plain = $1 } END { print (peeled != "" ? peeled : plain) }'
}
