#!/bin/bash
# Full NowPlaying widget rebuild pipeline: commit any pending source changes,
# push to the fork, wait for CI (henilptel/xcode-ci's reusable workflow),
# download the artifact, fix the MediaRemote.framework symlink structure
# (actions/upload-artifact flattens it — same class of bug MTMR's own
# rebuild-and-install.sh works around for Sparkle.framework), sign, install
# into Pock's Widgets folder, make sure Pock's own Touch Bar layout actually
# includes it (separate from just being "installed"), and relaunch Pock.
#
# Usage: scripts/rebuild-and-install.sh ["commit message"]
# (commit message only needed if there are uncommitted changes to push)
set -euo pipefail

REPO_DIR="$HOME/Work/Other/NowPlayingWidget"
FORK_REPO="henilptel/now-playing-widget"
WIDGETS_DIR="$HOME/Library/Application Support/Pock/Widgets"
WIDGET_NAME="NowPlaying.pock"
WIDGET_BUNDLE_ID="com.pigigaldi.pock.NowPlaying"
POCK_APP_PATH="/Applications/Pock.app"
POCK_PREFS_DOMAIN="com.pigigaldi.Pock"
COMMIT_MSG="${1:-}"

cd "$REPO_DIR"

echo "==> Checking for uncommitted changes..."
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git status --porcelain)" ]; then
  if [ -z "$COMMIT_MSG" ]; then
    echo "ERROR: uncommitted changes present but no commit message given." >&2
    echo "Usage: $0 \"commit message\"" >&2
    exit 1
  fi
  git add -A
  git commit -m "$COMMIT_MSG"
else
  echo "    no uncommitted changes."
fi

echo "==> Pushing to fork..."
git push origin master
COMMIT_SHA=$(git rev-parse HEAD)
echo "    pushed $COMMIT_SHA"

echo "==> Triggering 'Build artifact' workflow..."
gh workflow run "Build artifact" --repo "$FORK_REPO"
sleep 5

echo "==> Waiting for the run to appear..."
RUN_ID=""
for i in $(seq 1 20); do
  RUN_ID=$(gh run list --repo "$FORK_REPO" --workflow "Build artifact" --json databaseId,headSha,event --limit 5 \
    --jq ".[] | select(.headSha==\"$COMMIT_SHA\") | .databaseId" | head -1)
  [ -n "$RUN_ID" ] && break
  sleep 3
done
if [ -z "$RUN_ID" ]; then
  echo "ERROR: could not find the workflow run for this commit." >&2
  exit 1
fi
echo "    run id: $RUN_ID"

echo "==> Waiting for build to complete..."
until [ "$(gh run view "$RUN_ID" --repo "$FORK_REPO" --json status --jq '.status')" = "completed" ]; do
  sleep 10
done
CONCLUSION=$(gh run view "$RUN_ID" --repo "$FORK_REPO" --json conclusion --jq '.conclusion')
if [ "$CONCLUSION" != "success" ]; then
  echo "ERROR: build failed (conclusion: $CONCLUSION)." >&2
  echo "       Raw log: gh run view $RUN_ID --repo $FORK_REPO --log-failed" >&2
  echo "       See: https://github.com/$FORK_REPO/actions/runs/$RUN_ID" >&2
  exit 1
fi
echo "    build succeeded."

echo "==> Downloading artifact..."
BUILD_DIR=$(mktemp -d)
gh run download "$RUN_ID" --repo "$FORK_REPO" --dir "$BUILD_DIR" --name "NowPlaying-widget"

echo "==> Quitting Pock (by PID, not by name)..."
PIDS=$(pgrep -f "Pock.app/Contents/MacOS/Pock" || true)
if [ -n "$PIDS" ]; then
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
fi
REMAINING=$(pgrep -f "Pock.app/Contents/MacOS/Pock" || true)
if [ -n "$REMAINING" ]; then
  echo "ERROR: Pock still running after kill (pid(s): $REMAINING)." >&2
  exit 1
fi

echo "==> Backing up current widget..."
if [ -d "$WIDGETS_DIR/$WIDGET_NAME" ]; then
  BACKUP="$WIDGETS_DIR/$WIDGET_NAME.backup-$(date +%Y%m%dT%H%M%S)"
  cp -R "$WIDGETS_DIR/$WIDGET_NAME" "$BACKUP"
  echo "    backed up to: $BACKUP"
fi

echo "==> Installing new build..."
rm -rf "$WIDGETS_DIR/$WIDGET_NAME"
cp -R "$BUILD_DIR" "$WIDGETS_DIR/$WIDGET_NAME"

echo "==> Rebuilding MediaRemote.framework's symlink structure..."
# actions/upload-artifact zips the artifact, dereferencing symlinks —
# turns the framework's Versions/Current -> A indirection into duplicated
# real files, same as MTMR's Sparkle.framework issue. Versions/A already
# has the real (correct) content after download; only the symlinks and the
# duplicate Versions/Current copy need fixing.
MR="$WIDGETS_DIR/$WIDGET_NAME/Contents/Frameworks/MediaRemote.framework"
if [ -d "$MR/Versions/A" ]; then
  rm -rf "$MR/Versions/Current" "$MR/MediaRemote" "$MR/Resources" "$MR/Versions/A/_CodeSignature"
  (cd "$MR/Versions" && ln -s A Current)
  (cd "$MR" && ln -s Versions/Current/MediaRemote MediaRemote && ln -s Versions/Current/Resources Resources)
fi

echo "==> Signing..."
xattr -cr "$WIDGETS_DIR/$WIDGET_NAME"
# Sign the framework and the outer bundle separately, not --deep — deep
# signing chokes on the framework's non-standard root-level Support/
# directory ("unsealed contents present in the root directory").
codesign --force --sign - "$MR" 2>&1 || true
codesign --force --sign - "$WIDGETS_DIR/$WIDGET_NAME"
codesign -dv "$WIDGETS_DIR/$WIDGET_NAME" > /dev/null 2>&1 || {
  echo "ERROR: widget failed to sign." >&2
  exit 1
}

echo "==> Ensuring Pock's active Touch Bar layout includes the widget..."
# Being installed/enabled in Pock's "Widgets Manager" is a separate thing
# from actually being in the active bar arrangement (NSTouchBarConfig:
# PockTouchBarController -> CurrentItems). Without this, the widget is
# fully functional but simply never appears.
python3 - "$WIDGET_BUNDLE_ID" <<'PYEOF'
import plistlib, subprocess, sys, os

bundle_id = sys.argv[1]
path = os.path.expanduser("~/Library/Preferences/com.pigigaldi.Pock.plist")
with open(path, "rb") as f:
    data = plistlib.load(f)

key = "NSTouchBarConfig: PockTouchBarController"
config = data.setdefault(key, {"CurrentItems": [], "DefaultItems": []})
items = config.setdefault("CurrentItems", [])
if bundle_id not in items:
    items.append(bundle_id)
    config["CurrentItems"] = items
    with open(path, "wb") as f:
        plistlib.dump(data, f)
    print("    added to CurrentItems")
else:
    print("    already in CurrentItems")
PYEOF

echo "==> Launching Pock..."
open "$POCK_APP_PATH"
sleep 2
if ! pgrep -f "Pock.app/Contents/MacOS/Pock" > /dev/null; then
  echo "ERROR: Pock did not appear to launch." >&2
  exit 1
fi

echo ""
echo "==> Done. Pock is running:"
ps aux | grep -i "Pock.app/Contents/MacOS/Pock" | grep -v grep
