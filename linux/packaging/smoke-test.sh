#!/usr/bin/env bash
# Smoke test for a Linux build. Needs an X display and a session bus, e.g.
#   dbus-run-session -- xvfb-run -a linux/packaging/smoke-test.sh <bundle dir>
# Checks that Pastee starts and stays up, sets its summon shortcut and reacts
# to it (with xdotool, if installed), that `pastee --toggle` reaches the
# running copy, and that it quits cleanly.
set -euo pipefail

bundle=$(cd "${1:?usage: $0 <bundle dir>}" && pwd)
work=$(mktemp -d)
log=$work/pastee.log
pid=
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; fi
  rm -rf "$work"
}
trap cleanup EXIT

fail() {
  echo "::error::$1"
  echo "--- Pastee's log:"
  cat "$log"
  exit 1
}

# Waits up to $2 seconds for the log to contain $1.
wait_for() {
  for _ in $(seq "$(($2 * 10))"); do
    if grep -qF -- "$1" "$log"; then return 0; fi
    sleep 0.1
  done
  return 1
}

# Test data stays out of the real Pastee folder.
export XDG_DATA_HOME=$work/data
export G_MESSAGES_DEBUG=pastee
"$bundle/pastee" > "$log" 2>&1 &
pid=$!

wait_for "registerHotKey:" 60 || fail "Pastee didn't set up its summon shortcut"
grep -qF "registerHotKey: 0" "$log" || fail "The summon shortcut couldn't be registered"
sleep 5
kill -0 "$pid" 2>/dev/null || fail "Pastee exited"
echo "Pastee is running and registered Ctrl+Alt+V"

if command -v xdotool > /dev/null; then
  xdotool key ctrl+alt+v
  wait_for "summon:" 10 || fail "The summon shortcut didn't reach Pastee"
  echo "The summon shortcut reached Pastee"
fi

# A second pastee hands its command line to the running one over D-Bus and
# exits; without that it would start a second copy and time out here.
timeout 30 "$bundle/pastee" --toggle || fail "pastee --toggle failed ($?)"
wait_for "--toggle from another pastee" 10 || fail "pastee --toggle didn't reach the running Pastee"
kill -0 "$pid" 2>/dev/null || fail "Pastee exited after --toggle"
echo "pastee --toggle reached the running Pastee"

kill -TERM "$pid"
for _ in $(seq 100); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$pid" 2>/dev/null; then fail "Pastee didn't quit on SIGTERM"; fi
status=0
wait "$pid" || status=$?
pid=
[[ $status -eq 0 ]] || fail "Pastee exited with status $status"
echo "Pastee quit cleanly"
echo "--- Pastee's log:"
cat "$log"
