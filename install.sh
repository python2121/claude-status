#!/usr/bin/env bash
# Build (unless SKIP_BUILD=1), stop any running instance, replace the bundle
# in /Applications, and restart. Idempotent — safe to re-run after every code
# change.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeStatus"
APP_BUNDLE="${APP_NAME}.app"
DEST="/Applications/${APP_BUNDLE}"
LABEL="com.andrewnowicki.claudestatus"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
UID_NUM="$(id -u)"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  ./build-app.sh
fi

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "ERROR: ${APP_BUNDLE} not built — run ./build-app.sh first" >&2
  exit 1
fi

# Stop the LaunchAgent first so launchd doesn't respawn the old binary
# mid-replace. If it's not loaded, this is a no-op.
if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
  echo "==> stopping LaunchAgent"
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
fi

# Belt-and-braces — covers manually-launched instances not under launchd.
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> killing running ${APP_NAME}"
  pkill -x "${APP_NAME}" || true
  # Wait for it to actually exit before we overwrite the binary.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "${APP_NAME}" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    echo "==> ${APP_NAME} didn't exit, sending SIGKILL"
    pkill -9 -x "${APP_NAME}" || true
    sleep 0.5
  fi
fi

echo "==> installing to ${DEST}"
rm -rf "${DEST}"
cp -R "${APP_BUNDLE}" "${DEST}"

# Verify the installed copy still has a valid signature after the move.
if ! codesign --verify --verbose=1 "${DEST}" >/dev/null 2>&1; then
  echo "ERROR: ${DEST} fails signature verification after install" >&2
  exit 1
fi

# Register the PermissionRequest hook in ~/.claude/settings.json so approvals
# can be answered from the app. Idempotent (only touches its own marked
# entry, prints "Nothing to do" when already present). SKIP_HOOK=1 to opt
# out; remove later with: ClaudeStatus --uninstall-hook
if [[ "${SKIP_HOOK:-0}" != "1" ]]; then
  echo "==> registering Claude Code permission hook"
  "${DEST}/Contents/MacOS/${APP_NAME}" --install-hook
fi

# Start it. Prefer the LaunchAgent if the user has set one up — that way
# launchd will keep it alive and restart it on crash. Otherwise just open.
if [[ -f "${PLIST}" ]]; then
  echo "==> bootstrapping LaunchAgent"
  launchctl bootstrap "gui/${UID_NUM}" "${PLIST}"
else
  echo "==> opening ${DEST}"
  open "${DEST}"
fi

# Confirm it actually started.
sleep 1
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
  echo "==> done — ${APP_NAME} running (pid $(pgrep -x ${APP_NAME}))"
else
  echo "WARNING: ${APP_NAME} doesn't appear to be running." >&2
  exit 1
fi
