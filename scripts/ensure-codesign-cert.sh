#!/bin/sh
# Discovers or creates a local codesigning identity in the user's login keychain
# so macOS Screen Recording TCC permissions persist across `make build` / `make install`.
#
# Usage:
#   sh scripts/ensure-codesign-cert.sh [--print-identity] [--create]

set -eu

CERT_NAME="${CLIPLINE_CODESIGN_CERT_NAME:-ClipLine Local Signer}"
PRINT_ONLY=0
ALLOW_CREATE=0

for arg in "$@"; do
    case "$arg" in
        --print-identity) PRINT_ONLY=1 ;;
        --create) ALLOW_CREATE=1 ;;
        *)
            printf 'Usage: %s [--print-identity] [--create]\n' "$0" >&2
            exit 1
            ;;
    esac
done

# Only inspect the real user's login keychain when HOME matches the account's home directory.
REAL_HOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory:[[:space:]]*//p' || true)
if [ -n "$REAL_HOME" ] && [ "${HOME:-}" != "$REAL_HOME" ]; then
    exit 0
fi

ANCHORED_FINGERPRINT=$(defaults read io.github.clipline CodesignIdentitySHA1 2>/dev/null || true)

LOGIN_KEYCHAIN=$(security default-keychain -d user 2>/dev/null | sed -n 's/.*"\(.*\)".*/\1/p')
if [ -z "$LOGIN_KEYCHAIN" ] || [ ! -f "$LOGIN_KEYCHAIN" ]; then
    if [ -n "$ANCHORED_FINGERPRINT" ] && [ "$ALLOW_CREATE" != "1" ]; then
        printf '❌ Default login keychain is unavailable while anchored code signing identity %s is configured.\n' "$ANCHORED_FINGERPRINT" >&2
        exit 1
    fi
    if [ "$ALLOW_CREATE" = "1" ]; then
        printf '❌ Default login keychain is unavailable; cannot create local code signing identity.\n' >&2
        exit 1
    fi
    exit 0
fi

find_valid_identity() {
    identities=$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null || true)
    if [ -n "$ANCHORED_FINGERPRINT" ]; then
        anchored=$(printf '%s\n' "$identities" | awk -v fp="$ANCHORED_FINGERPRINT" '$2 == fp { print $2; exit }')
        if [ -n "$anchored" ]; then
            printf '%s\n' "$anchored"
            return 0
        fi
        # Do not silently fall through to a different certificate if an anchored fingerprint is configured
        # unless `--create` was explicitly requested to re-establish signing.
        if [ "$ALLOW_CREATE" != "1" ]; then
            return 1
        fi
    fi
    preferred=$(printf '%s\n' "$identities" | grep "\"$CERT_NAME\"" | awk 'NF >= 2 { print $2; exit }' || true)
    if [ -n "$preferred" ]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    fallback=$(printf '%s\n' "$identities" | awk '/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-Fa-f]{40}[[:space:]]+"/ { print $2; exit }' || true)
    if [ -n "$fallback" ]; then
        printf '%s\n' "$fallback"
        return 0
    fi
    return 1
}

EXISTING_ID=$(find_valid_identity || true)
if [ -n "$EXISTING_ID" ]; then
    if [ -z "$ANCHORED_FINGERPRINT" ] || [ "$ALLOW_CREATE" = "1" ]; then
        defaults write io.github.clipline CodesignIdentitySHA1 -string "$EXISTING_ID" 2>/dev/null || true
    fi
    if [ "$PRINT_ONLY" = "1" ]; then
        printf '%s\n' "$EXISTING_ID"
    else
        printf '✅ Using existing code signing identity: %s\n' "$EXISTING_ID"
    fi
    exit 0
fi

if [ -n "$ANCHORED_FINGERPRINT" ] && [ "$ALLOW_CREATE" != "1" ]; then
    printf '❌ Anchored code signing identity %s was not found in %s (run `make setup-codesign` or `defaults delete io.github.clipline CodesignIdentitySHA1` to reset).\n' "$ANCHORED_FINGERPRINT" "$LOGIN_KEYCHAIN" >&2
    exit 1
fi

if [ "$ALLOW_CREATE" != "1" ]; then
    exit 0
fi

if [ "${CLIPLINE_SKIP_LAUNCHCTL:-0}" = "1" ] || [ -n "${CI:-}" ] || [ ! -t 0 ]; then
    printf '❌ Cannot create a local code signing certificate in a non-interactive or CI shell.\n' >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/clipline-codesign.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/cert.conf" <<EOF
[ req ]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no

[ req_dn ]
CN = $CERT_NAME

[ codesign_ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOF

printf "🔐 Generating local self-signed code signing certificate '%s'...\n" "$CERT_NAME" >&2
printf "   (macOS may prompt once for your login password to trust the certificate for code signing,\n" >&2
printf "    so Screen Recording permission is preserved across rebuilds and updates.)\n" >&2

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" \
    -days 3650 \
    -config "$tmpdir/cert.conf" 2>/dev/null

security import "$tmpdir/cert.pem" -k "$LOGIN_KEYCHAIN" >/dev/null
security import "$tmpdir/key.pem" -k "$LOGIN_KEYCHAIN" -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$tmpdir/cert.pem"

NEW_ID=$(find_valid_identity || true)
if [ -n "$NEW_ID" ]; then
    defaults write io.github.clipline CodesignIdentitySHA1 -string "$NEW_ID" 2>/dev/null || true
    if [ "$PRINT_ONLY" = "1" ]; then
        printf '%s\n' "$NEW_ID"
    else
        printf '✅ Created and trusted local code signing identity: %s\n' "$NEW_ID"
    fi
else
    printf '❌ Could not verify trusted code signing identity after import.\n' >&2
    exit 1
fi
