#!/bin/sh
# Run after make build. Never starts the GUI or touches the real installation.
set -eu
cd "$(dirname "$0")/.."
root=$(mktemp -d "${TMPDIR:-/tmp}/clipline-install.XXXXXX")
test_home="$root/test home"
install_dir="$test_home/.local/bin"
other_pid=
installed_pid=
trap 'kill ${other_pid:-} ${installed_pid:-} 2>/dev/null || true' EXIT

mkdir -p "$install_dir" "$root/other"
cp build/clipline "$install_dir/clipline"
help=$("$install_dir/clipline" --help)
printf '%s\n' "$help"
case "$help" in
    *"--update"*) ;;
    *) echo "FAIL: --help does not list --update" >&2; exit 1 ;;
esac
case "$help" in
    *"--doctor"*) ;;
    *) echo "FAIL: --help does not list --doctor" >&2; exit 1 ;;
esac
version_out=$("$install_dir/clipline" --version)
printf '%s\n' "$version_out"
expected_ver=$(tr -d '[:space:]' < VERSION)
case "$version_out" in
    "ClipLine $expected_ver "*) ;;
    *) echo "FAIL: --version output ($version_out) does not match VERSION ($expected_ver)" >&2; exit 1 ;;
esac

doctor_json=$("$install_dir/clipline" --doctor --json)
case "$doctor_json" in
    *"\"version\" : \"$expected_ver\""*) ;;
    *) echo "FAIL: --doctor --json output did not contain expected version $expected_ver" >&2; exit 1 ;;
esac
if "$install_dir/clipline" --doctor --unknown-flag >/dev/null 2>&1; then
    echo "FAIL: --doctor should reject unknown trailing flags" >&2
    exit 1
fi

# Stand-in processes exercise path-scoped termination, not GUI/TCC state.
mv "$install_dir/clipline" "$root/compiled-clipline"
printf '#include <unistd.h>\nint main(void) { sleep(120); return 0; }\n' | \
    cc -x c - -o "$install_dir/clipline"
cp "$install_dir/clipline" "$root/other/clipline"
"$install_dir/clipline" 120 &
installed_pid=$!
"$root/other/clipline" 120 &
other_pid=$!
sleep 1
kill -0 "$installed_pid"
kill -0 "$other_pid"

make uninstall HOME="$test_home" CLIPLINE_SKIP_LAUNCHCTL=1
sleep 1
if kill -0 "$installed_pid" 2>/dev/null; then
    echo "FAIL: uninstall did not stop the installed process" >&2
    exit 1
fi
wait "$installed_pid" 2>/dev/null || true
installed_pid=
test ! -e "$install_dir/clipline"
kill -0 "$other_pid"
make uninstall HOME="$test_home" CLIPLINE_SKIP_LAUNCHCTL=1

make install HOME="$test_home"
"$install_dir/clipline" --help
cmp build/clipline "$install_dir/clipline"
make install-service HOME="$test_home" CLIPLINE_SKIP_LAUNCHCTL=1
plutil -lint "$test_home/Library/LaunchAgents/io.github.clipline.daemon.plist"
make uninstall HOME="$test_home" CLIPLINE_SKIP_LAUNCHCTL=1
test ! -e "$test_home/Library/LaunchAgents/io.github.clipline.daemon.plist"
make install HOME="$test_home"
printf 'PASS: scoped uninstall, repeat uninstall, spaced paths, LaunchAgent plist, and reinstall. Artifacts: %s\n' "$root"

# Verify ensure-codesign-cert.sh fail-closed behavior under isolated mock PATH/HOME without touching real keychain
mock_bin="$root/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/dscl" <<'MOCK'
#!/bin/sh
printf 'NFSHomeDirectory: %s\n' "$HOME"
MOCK
cat > "$mock_bin/security" <<'MOCK'
#!/bin/sh
printf '"/__clipline_smoke_missing_keychain__"\n'
MOCK
cat > "$mock_bin/defaults" <<'MOCK'
#!/bin/sh
if [ "$1" = "read" ]; then
    printf '%s' "${CLIPLINE_MOCK_ANCHOR:-}"
    exit 0
fi
exit 1
MOCK
chmod +x "$mock_bin/dscl" "$mock_bin/security" "$mock_bin/defaults"

if env PATH="$mock_bin:$PATH" HOME="$test_home" CLIPLINE_MOCK_ANCHOR="" sh scripts/ensure-codesign-cert.sh --create >/dev/null 2>"$root/codesign_err.txt"; then
    echo "FAIL: ensure-codesign-cert.sh --create should exit nonzero when default keychain is unavailable" >&2
    exit 1
fi
case "$(cat "$root/codesign_err.txt")" in
    *"Default login keychain is unavailable; cannot create"*) ;;
    *) echo "FAIL: unexpected stderr for missing keychain --create: $(cat "$root/codesign_err.txt")" >&2; exit 1 ;;
esac
if env PATH="$mock_bin:$PATH" HOME="$test_home" CLIPLINE_MOCK_ANCHOR="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" sh scripts/ensure-codesign-cert.sh --print-identity >/dev/null 2>"$root/codesign_anchor_err.txt"; then
    echo "FAIL: ensure-codesign-cert.sh --print-identity should exit nonzero when anchored identity has no keychain" >&2
    exit 1
fi
