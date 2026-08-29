#!/bin/bash
#
# Stamp the built app bundle with the build's git version, in the same format the
# firmwares and the Android app use:
#
#     YYYY.MM.DD-<git describe --tags --long --dirty --always>[.HHMMSS when dirty]
#
# **Written into a RESOURCE, never compiled into the binary**, and that is
# load-bearing rather than a style preference. On Android the first cut used a
# `buildConfigField`, which emits a `public static final String` — a compile-time
# constant, so the compiler inlines it into whichever class reads it. Regenerating
# it then updated `BuildConfig.class` and nothing else, and the screen kept
# displaying the literal it had been compiled against: an APK that shipped BOTH
# strings, with the three-hour-old one on screen (app `206960c`).
#
# Swift has the same hazard by a different route: a generated `.swift` `let` is a
# `let` the optimiser is free to fold into its readers, and whether it does depends
# on the optimisation level and on whether incremental compilation decided to
# rebuild the reader. A file in the bundle cannot be folded into anything —
# `AppVersion` reads it by name at runtime, and this phase rewrites it on every
# build (`alwaysOutOfDate`), so the value on screen is the value from this build or
# the app says it does not know.
#
# The firmwares never hit any of this because `version.h` is a real prerequisite of
# `Communication.o`, which forces the recompile.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"

# git describe must run inside the repo, not in whatever directory Xcode invoked us
# from.
cd "$ROOT" || exit 1

# Refresh the index before asking about --dirty. Hygiene, not a fix for a
# demonstrated bug, and the distinction is recorded so nobody credits it with more
# than it does: `git describe --dirty` decides via `git diff-index`, which does not
# refresh the index first — the same reason git's own require_clean_work_tree
# refreshes before testing. A non-zero exit means genuinely modified files, which is
# the case --dirty exists to report, so the result is ignored rather than checked.
git update-index -q --refresh || true

# --always so a repo with no tags still yields the short hash rather than failing;
# --long so tags, once they exist, carry their distance.
DESCRIBE="$(git describe --tags --long --dirty --always 2>/dev/null || echo unknown)"
VERSION="$(date +%Y.%m.%d)-${DESCRIBE}"

# A dirty tree describes IDENTICALLY for as long as it stays dirty: --dirty says
# only THAT something is uncommitted, never what. So every build made between two
# commits on the same day would otherwise carry a byte-identical stamp, and the
# version a device reports stops distinguishing the build actually on it — which on
# the firmware side once cost a debugging round that blamed the wrong board.
case "$DESCRIBE" in
*-dirty) VERSION="${VERSION}.$(date +%H%M%S)" ;;
esac

# The bundle's resources directory, which the Resources build phase has already
# created by the time this phase runs.
OUTDIR="${BUILT_PRODUCTS_DIR:-.}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
mkdir -p "$OUTDIR"
printf '%s' "$VERSION" > "$OUTDIR/GitVersion.txt"

echo "note: app version stamp ${VERSION}"
