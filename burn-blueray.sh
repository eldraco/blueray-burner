#!/usr/bin/env bash
set -euo pipefail

# burn-blueray.sh
# Create (or reuse) image and burn with drutil.
# Robust against:
# - existing image reuse (--image)
# - macOS extension oddities (.iso appended)
# - missing optical device/media before burn
#
# Usage:
#   ./burn-blueray.sh -s "<source_folder>" -t "<stage_folder>" [--bdxl|--dvd] [-v VOL] [-x SPEED] [--dry-run]
#   ./burn-blueray.sh --image "<existing_image>" [-x SPEED] [--dry-run]
#
# Examples:
#   ./burn-blueray.sh -s "/Volumes/DataMa/..." -t "/Volumes/Third" --bdxl -x 2 -v "Backup GooglePhotos1"
#   ./burn-blueray.sh --image "/Volumes/Third/BDXL_BACKUP.udf.dmg.iso" -x 2
#   ./burn-blueray.sh --image "/Volumes/Third/BDXL_BACKUP.udf.dmg.iso" --dry-run

DRY_RUN=0
MODE="bdxl"      # dvd | bdxl
VOL="BD_BACKUP"
SPEED=""
SRC=""
STAGE=""
IMG_IN=""

die() { echo "ERROR: $*" >&2; exit 1; }

show_help() {
  cat <<'EOF'
Usage:
  burn-blueray.sh [OPTIONS]

Create mode:
  -s, --source <path>     Source folder to write to disc
  -t, --stage  <path>     Writable folder where image is created

Reuse mode:
      --image <path>      Existing image file to burn (skips creation)

Mode (create mode only; default: --bdxl):
      --bdxl              Capacity guard for 100GB BDXL (~100.10GB with margin)
      --dvd               Capacity guard for DVD 4.7GB (with margin)

Options:
  -v, --volume <name>     Volume label (default: BD_BACKUP)
  -x, --speed  <num>      Burn speed (use supported speed, e.g. 2)
      --dry-run           Do everything except actual burn
  -h, --help              Show this help

Examples:
  Create + burn BDXL:
    ./burn-blueray.sh -s "/Volumes/DataMa/..." -t "/Volumes/Third" --bdxl -x 2 -v "Backup GooglePhotos1"

  Reuse existing image + burn:
    ./burn-blueray.sh --image "/Volumes/Third/BDXL_BACKUP.udf.dmg.iso" -x 2

  Reuse existing image, no burn:
    ./burn-blueray.sh --image "/Volumes/Third/BDXL_BACKUP.udf.dmg.iso" --dry-run
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source) SRC="${2:-}"; shift 2;;
    -t|--stage)  STAGE="${2:-}"; shift 2;;
    -v|--volume) VOL="${2:-}"; shift 2;;
    -x|--speed)  SPEED="${2:-}"; shift 2;;
    --image)     IMG_IN="${2:-}"; shift 2;;
    --dry-run)   DRY_RUN=1; shift;;
    --dvd)       MODE="dvd"; shift;;
    --bdxl)      MODE="bdxl"; shift;;
    -h|--help)   show_help; exit 0;;
    *) die "Unknown option: $1 (use -h)";;
  esac
done

need_cmd hdiutil
need_cmd drutil
need_cmd du
need_cmd df
need_cmd awk
need_cmd stat
need_cmd grep
need_cmd sed

# Validate an image by attaching it read-only (more reliable than
# `hdiutil imageinfo`, which can return non-zero for large raw/UDF hybrids).
validate_image_readable() {
  local img="$1"
  local attach_out dev

  attach_out="$(hdiutil attach -nomount -readonly "$img" 2>&1)" || {
    echo "$attach_out" >&2
    return 1
  }

  dev="$(printf '%s\n' "$attach_out" | awk 'NR==1 {print $1}')"
  [[ -n "$dev" ]] || {
    echo "hdiutil attach returned no device for image: $img" >&2
    echo "$attach_out" >&2
    return 1
  }

  local i
  for i in 1 2 3; do
    hdiutil detach "$dev" >/dev/null 2>&1 && return 0
    hdiutil detach -force "$dev" >/dev/null 2>&1 && return 0
    sleep 1
  done

  echo "Failed to detach temporary device: $dev" >&2
  return 1
}

# Keep system awake during long operations
caffeinate -dimsu &
CAFPID=$!
trap 'kill "$CAFPID" >/dev/null 2>&1 || true' EXIT

IMG=""

if [[ -n "$IMG_IN" ]]; then
  # Reuse existing image
  [[ -f "$IMG_IN" ]] || die "Image not found: $IMG_IN"
  [[ -s "$IMG_IN" ]] || die "Image is empty: $IMG_IN"
  validate_image_readable "$IMG_IN" || die "Invalid/unreadable image: $IMG_IN"
  IMG="$IMG_IN"
  echo "[INFO] Reusing existing image: $IMG"
else
  # Create image mode requires source + stage
  [[ -n "$SRC" ]]   || die "Missing --source (or provide --image)"
  [[ -n "$STAGE" ]] || die "Missing --stage (or provide --image)"
  [[ -d "$SRC" ]]   || die "Source folder not found: $SRC"
  [[ -d "$STAGE" ]] || die "Staging folder not found: $STAGE"

  # Writable stage check
  TESTFILE="$STAGE/.burn_write_test_$$"
  touch "$TESTFILE" 2>/dev/null || die "Cannot write to staging folder: $STAGE"
  rm -f "$TESTFILE"

  # Capacity guards (only when creating)
  if [[ "$MODE" == "bdxl" ]]; then
    LIMIT_BYTES=$((100100000000 - 300*1024*1024))   # 100.10GB - 300MiB
    MARGIN=$((300*1024*1024))
  elif [[ "$MODE" == "dvd" ]]; then
    LIMIT_BYTES=$((4710000000 - 100*1024*1024))     # 4.71GB - 100MiB
    MARGIN=$((100*1024*1024))
  else
    die "Invalid mode: $MODE"
  fi

  SRC_BYTES=$(( $(du -sk "$SRC" | awk '{print $1}') * 1024 ))
  [[ "$SRC_BYTES" -lt "$LIMIT_BYTES" ]] || die "Source too large for mode=$MODE"

  FREE_BYTES=$(( $(df -k "$STAGE" | awk 'NR==2 {print $4}') * 1024 ))
  NEEDED=$((SRC_BYTES + MARGIN))
  [[ "$FREE_BYTES" -gt "$NEEDED" ]] || die "Not enough free space on stage volume"

  TS="$(date +%Y%m%d_%H%M%S)"
  IMG="$STAGE/${VOL}_${TS}.iso"

  echo "[INFO] Creating image..."
  echo "[INFO] Source: $SRC"
  echo "[INFO] Stage : $STAGE"
  echo "[INFO] Out   : $IMG"

  if [[ "$MODE" == "dvd" ]]; then
    hdiutil makehybrid -o "$IMG" "$SRC" -iso -joliet -default-volume-name "$VOL" >/dev/null
  else
    # UDF + ISO/Joliet for BD data compatibility
    hdiutil makehybrid -o "$IMG" "$SRC" -udf -udf-volume-name "$VOL" -iso -joliet >/dev/null
  fi

  # macOS may append extra .iso in some environments
  if [[ ! -f "$IMG" && -f "${IMG}.iso" ]]; then
    mv "${IMG}.iso" "$IMG"
  fi

  [[ -f "$IMG" ]] || die "Image file not found after creation: $IMG"
  [[ -s "$IMG" ]] || die "Created image is empty: $IMG"
  validate_image_readable "$IMG" || die "Created image is not readable: $IMG"

  IMG_BYTES="$(stat -f%z "$IMG")"
  echo "[INFO] Image ready: $IMG"
  echo "[INFO] Image size : $IMG_BYTES bytes"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Burn skipped."
  echo "[DRY-RUN] Image: $IMG"
  exit 0
fi

# Require ready optical device + media before burn
STATUS="$(drutil status 2>/dev/null || true)"
echo "[INFO] Current drive/media:"
echo "$STATUS"

DEV="$(echo "$STATUS" | awk '/Name: \/dev\/disk[0-9]+/{print $3; exit}')"
TYPE="$(echo "$STATUS" | awk '/Type:/{print $2; exit}')"

[[ -n "$DEV" ]]  || die "No optical device/media found. Reconnect drive and insert disc."
[[ -n "$TYPE" ]] || die "No media type detected. Insert writable media."

echo "[INFO] Using device: $DEV (media: $TYPE)"
echo "[INFO] Burning image: $IMG"

# Try explicit drive first; fallback to default selection.
if [[ -n "$SPEED" ]]; then
  drutil burn -drive "$DEV" -speed "$SPEED" "$IMG" || drutil burn -speed "$SPEED" "$IMG"
else
  drutil burn -drive "$DEV" "$IMG" || drutil burn "$IMG"
fi

echo "[INFO] Burn completed."
