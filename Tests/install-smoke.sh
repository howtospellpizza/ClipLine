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

make uninstall HOME="$test_home"
sleep 1
if kill -0 "$installed_pid" 2>/dev/null; then
    echo "FAIL: uninstall did not stop the installed process" >&2
    exit 1
fi
wait "$installed_pid" 2>/dev/null || true
installed_pid=
test ! -e "$install_dir/clipline"
kill -0 "$other_pid"
make uninstall HOME="$test_home"

make install HOME="$test_home"
"$install_dir/clipline" --help
cmp build/clipline "$install_dir/clipline"
printf 'PASS: scoped uninstall, repeat uninstall, spaced paths, and reinstall. Artifacts: %s\n' "$root"
