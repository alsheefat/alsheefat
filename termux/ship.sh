#!/data/data/com.termux/files/usr/bin/bash
# ship.sh - the whole release process in one command.
#
#   1. Save the new tar in your Downloads folder, named  AUSSNSC.tar<number>.gz  (e.g. AUSSNSC.tar5.gz)
#   2. In Termux run:   bash ~/ship.sh
#
# It unpacks the tar into ~/AUSSNSC, pushes it to your GitHub repo, waits for GitHub Actions to
# build the APK, and downloads  AUSSNSC-v<number>.apk  to Downloads (then opens the installer).
# The server on Render redeploys itself from the same push.
#
# Options:   bash ship.sh [path/to/AUSSNSC.tarN.gz] [--server https://x.onrender.com] [--force] [--download-only]
set -eu

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
CONF="$HOME/.aussnsc.conf"
PROJECT="$HOME/AUSSNSC-upload"
DL="$HOME/storage/downloads"

say() { printf '\n== %s ==\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

FORCE=0; DLONLY=0; TAR=""; SERVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --download-only) DLONLY=1 ;;
    --server) shift; SERVER="${1%/}" ;;
    *) TAR="$1" ;;
  esac
  shift
done

# ---------- tools ----------
MISSING=""
for t in git gh tar curl; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  say "Installing:$MISSING"
  pkg install -y $MISSING
fi
if [ ! -d "$DL" ] && command -v termux-setup-storage >/dev/null 2>&1; then
  say "Allow storage access (tap Allow), then run this again"
  termux-setup-storage
  sleep 5
fi

# ---------- GitHub login (once) ----------
if ! gh auth status >/dev/null 2>&1; then
  say "GitHub login"
  echo "A code will appear. Open https://github.com/login/device in your browser and type it in."
  gh auth login -p https -w
fi
gh auth setup-git >/dev/null 2>&1 || true
GH_USER="$(gh api user -q .login)"
git config --global user.name  >/dev/null 2>&1 || git config --global user.name  "$GH_USER"
git config --global user.email >/dev/null 2>&1 || git config --global user.email "$GH_USER@users.noreply.github.com"

# ---------- remembered settings ----------
REPO=""; RENDER_URL=""; ASKED_URL=""
[ -f "$CONF" ] && . "$CONF"
if [ -z "$REPO" ]; then
  printf 'Name for your GitHub repository [aussnsc]: '; read -r REPO; REPO="${REPO:-aussnsc}"
fi
if [ -n "$SERVER" ]; then
  RENDER_URL="$SERVER"
elif [ -z "$RENDER_URL" ] && [ -z "$ASKED_URL" ]; then
  printf 'Your Render server URL, e.g. https://aussnsc-api.onrender.com (Enter to skip for now): '; read -r RENDER_URL
  RENDER_URL="${RENDER_URL%/}"
fi
printf 'REPO=%q\nRENDER_URL=%q\nASKED_URL=1\n' "$REPO" "$RENDER_URL" > "$CONF"
SLUG="$GH_USER/$REPO"

download_apk() {
  local n="$1" out="$DL"
  [ -d "$out" ] || out="$HOME"
  say "Downloading the APK"
  gh release download "v$n" -R "$SLUG" -p "AUSSNSC-v$n.apk" -D "$out" --clobber
  echo "Saved: $out/AUSSNSC-v$n.apk"
  if command -v termux-open >/dev/null 2>&1; then termux-open "$out/AUSSNSC-v$n.apk" || true; fi
}

if [ "$DLONLY" -eq 1 ]; then
  LATEST="$(gh release list -R "$SLUG" --limit 50 --json tagName -q '.[].tagName' | grep -E '^v[0-9]+$' | sort -t v -k2 -n -r | head -n 1)"
  [ -n "$LATEST" ] || die "No numbered release found yet."
  download_apk "${LATEST#v}"
  exit 0
fi

# ---------- find the tar ----------
if [ -z "$TAR" ]; then
  BEST=0
  for d in "$DL" "$HOME/storage/shared/Download" "$HOME" "$PWD"; do
    for f in "$d"/AUSSNSC.tar*.gz; do
      [ -f "$f" ] || continue
      n="$(basename "$f" | sed -n 's/^AUSSNSC\.tar\([0-9][0-9]*\)\.gz$/\1/p')"
      if [ -n "$n" ] && [ "$n" -gt "$BEST" ]; then BEST="$n"; TAR="$f"; fi
    done
  done
fi
[ -n "$TAR" ] && [ -f "$TAR" ] || die "No AUSSNSC.tar<number>.gz found. Put the new tar in Downloads (for example AUSSNSC.tar5.gz)."
N="$(basename "$TAR" | sed -n 's/^AUSSNSC\.tar\([0-9][0-9]*\)\.gz$/\1/p')"
[ -n "$N" ] || die "Rename the file to AUSSNSC.tar<number>.gz (for example AUSSNSC.tar5.gz)."

CUR="$(cat "$PROJECT/VERSION" 2>/dev/null || echo 0)"
if [ "$N" -le "$CUR" ] && [ "$FORCE" -eq 0 ]; then
  die "tar$N is not newer than the version already shipped (v$CUR). Use a higher number, or add --force."
fi

# ---------- unpack ----------
say "Unpacking tar$N"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar xzf "$TAR" -C "$WORK" || die "Could not open $TAR (is the download complete?)"
if [ -d "$WORK/AUSSNSC" ]; then SRC="$WORK/AUSSNSC"; else SRC="$WORK"; fi
if [ ! -d "$SRC/android" ] && [ ! -d "$SRC/backend" ] && [ ! -d "$SRC/.github" ]; then
  die "This tar doesn't look like an AUSSNSC project."
fi
# a full release mirrors the project (deleted files disappear); a partial patch only overlays its files
DELETE=""
if [ -d "$SRC/android" ] && [ -d "$SRC/backend" ] && [ -f "$SRC/render.yaml" ]; then DELETE="--delete"; else echo "(partial patch: only the files in the tar are replaced)"; fi

# never let a tar overwrite your git history, Firebase file or server address
rm -rf "$SRC/.git" "$SRC/android/app/google-services.json" "$SRC/android/api.properties"
mkdir -p "$PROJECT"
if [ -n "$DELETE" ] && [ -d "$PROJECT/.git" ]; then
  # full release: remove the files git knows about, then copy the new ones (so deleted files really disappear)
  ( cd "$PROJECT" && git ls-files | grep -v -e '^android/api.properties$' | while IFS= read -r f; do rm -f -- "$f"; done )
fi
cp -a "$SRC/." "$PROJECT/"
echo "$N" > "$PROJECT/VERSION"
mkdir -p "$PROJECT/android"
if [ -n "$RENDER_URL" ]; then echo "API_BASE_URL=${RENDER_URL%/}/api/v1/" > "$PROJECT/android/api.properties"; fi

# ---------- GitHub repository ----------
cd "$PROJECT"
[ -d .git ] || git init -q -b main
REMOTE_URL="${SHIP_REMOTE:-https://github.com/$SLUG.git}"
if ! git remote get-url origin >/dev/null 2>&1; then
  if ! gh repo view "$SLUG" >/dev/null 2>&1; then
    say "Creating private repository $SLUG"
    gh repo create "$SLUG" --public >/dev/null
  fi
  git remote add origin "$REMOTE_URL"
fi

# Firebase config -> GitHub secret (only when it changed)
GS="$PROJECT/android/app/google-services.json"
if [ ! -f "$GS" ] && [ -f "$DL/google-services.json" ]; then cp "$DL/google-services.json" "$GS"; fi
if [ -f "$GS" ]; then
  H="$(sha256sum "$GS" | cut -d' ' -f1)"
  if [ "$(cat .git/aussnsc-gs.sha 2>/dev/null || true)" != "$H" ]; then
    base64 -w0 "$GS" | gh secret set GOOGLE_SERVICES_JSON -R "$SLUG" >/dev/null
    echo "$H" > .git/aussnsc-gs.sha
    echo "Firebase config stored as a GitHub secret."
  fi
else
  echo "NOTE: google-services.json not found - the APK will be built WITHOUT Google sign-in."
  echo "      (Save it in Downloads and run this again to add it.)"
fi

# ---------- push = start the pipeline ----------
say "Uploading to GitHub"
git add -A
CHANGED=1
if git diff --cached --quiet; then CHANGED=0; else
  git diff --cached --stat | tail -n 4
  git commit -q -m "Release v$N" -m "Shipped from AUSSNSC.tar$N.gz"
fi
git push -q -u origin main || die "Push failed. If GitHub says the history differs, run:  cd $PROJECT && git push --force-with-lease origin main"
SHA="$(git rev-parse HEAD)"
if [ "$CHANGED" -eq 0 ]; then
  echo "Nothing changed since the last upload - starting a rebuild."
  gh workflow run build-apk.yml -R "$SLUG" >/dev/null 2>&1 || true
fi

# ---------- wait for the build ----------
say "GitHub is building v$N (about 5-8 minutes)"
RUN=""
for _ in $(seq 1 24); do
  RUN="$(gh run list -R "$SLUG" --workflow build-apk.yml --commit "$SHA" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN" ] && break
  sleep 5
done
[ -n "$RUN" ] || die "The build did not start. Open https://github.com/$SLUG/actions to see why."

while :; do
  ST="$(gh run view "$RUN" -R "$SLUG" --json status,conclusion -q '.status + " " + .conclusion' 2>/dev/null || echo "unknown")"
  case "$ST" in completed*) break ;; esac
  printf '  %s  [%s]\n' "$ST" "$(date +%H:%M:%S)"
  sleep 15
done
RESULT="${ST#completed }"

if [ "$RESULT" != "success" ]; then
  LOG="$HOME/aussnsc-build-error.txt"; [ -d "$DL" ] && LOG="$DL/aussnsc-build-error.txt"
  gh run view "$RUN" -R "$SLUG" --log-failed 2>&1 | tail -n 150 > "$LOG" || true
  echo; echo "---- last lines of the failed build ----"; tail -n 25 "$LOG"
  die "The build failed ($RESULT). Full error saved to: $LOG  - send that file to me. Page: https://github.com/$SLUG/actions/runs/$RUN"
fi

download_apk "$N"

# ---------- housekeeping ----------
if [ -n "$RENDER_URL" ]; then
  echo; echo "Server check: $(curl -s -m 70 "${RENDER_URL%/}/health" || echo 'not answering yet (a free server may still be starting)')"
fi
if [ -f "$PROJECT/termux/ship.sh" ] && ! cmp -s "$PROJECT/termux/ship.sh" "$SELF"; then
  cp "$PROJECT/termux/ship.sh" "$HOME/ship.sh.new" && mv "$HOME/ship.sh.new" "$HOME/ship.sh" && echo "ship.sh updated to the newest version."
fi
say "Done - v$N is installed-ready"
echo "All releases: https://github.com/$SLUG/releases"
