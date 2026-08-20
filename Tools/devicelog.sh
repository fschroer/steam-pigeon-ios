#!/usr/bin/env bash
# devicelog.sh — capture the iPhone's console, filtered to this app.
#
# Xcode cannot stream a runtime log for us: `log stream` has no --device flag on
# current macOS, and `devicectl` needs iOS 17+ while the bench phone runs 16.7.
# idevicesyslog (brew install libimobiledevice) works over USB on iOS 16, which is
# the only path to runtime messages short of reading them off the screen.
#
# Usage:
#   Tools/devicelog.sh              # 30 s, SteamPigeon lines only
#   Tools/devicelog.sh 120          # 120 s
#   Tools/devicelog.sh 60 all       # 60 s, everything (noisy: ~2000 lines/s)
#
# Output goes to stdout and to /tmp/steampigeon-device.log.

set -u
SECONDS_TO_CAPTURE="${1:-30}"
SCOPE="${2:-app}"
OUT=/tmp/steampigeon-device.log

command -v idevicesyslog >/dev/null 2>&1 || {
  echo "idevicesyslog not found. Install it with:  brew install libimobiledevice" >&2
  exit 1
}

UDID=$(idevice_id -l 2>/dev/null | head -1)
[ -n "$UDID" ] || {
  echo "No device found. Plug the iPhone in, unlock it, and trust this computer." >&2
  exit 1
}

echo "Capturing ${SECONDS_TO_CAPTURE}s from $(ideviceinfo -k DeviceName 2>/dev/null)" \
     "(iOS $(ideviceinfo -k ProductVersion 2>/dev/null)) -> $OUT" >&2

idevicesyslog --no-colors -u "$UDID" -o "$OUT" >/dev/null 2>&1 &
LOGGER=$!
# shellcheck disable=SC2064
trap "kill $LOGGER 2>/dev/null" EXIT
sleep "$SECONDS_TO_CAPTURE"
kill $LOGGER 2>/dev/null
wait $LOGGER 2>/dev/null

TOTAL=$(wc -l < "$OUT" | tr -d ' ')
if [ "$SCOPE" = "all" ]; then
  echo "--- $TOTAL lines ---" >&2
  cat "$OUT"
else
  # Anything the app emitted, plus the runtime complaints that name no process —
  # SwiftUI's "Modifying state during view update" among them, which is exactly the
  # class of message this exists to catch.
  MATCHED=$(grep -icE "SteamPigeon|SwiftUI|CoreBluetooth" "$OUT" || true)
  echo "--- $MATCHED of $TOTAL lines matched ---" >&2
  grep -iE "SteamPigeon|SwiftUI|CoreBluetooth" "$OUT" || echo "(nothing matched — is the app running?)"
fi
