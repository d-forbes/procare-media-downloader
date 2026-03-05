#!/bin/bash
# =============================================================================
# ProCare Connect - Download All Photos & Videos with Metadata
# =============================================================================
# Downloads all photos and videos from the ProCare Connect parent API,
# then embeds date and caption metadata using exiftool.
#
# Usage: bash download_media.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — loaded from .env
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "  Copy the example and fill in your values:"
  echo "    cp .env.example .env"
  exit 1
fi

# shellcheck source=.env
source "$ENV_FILE"

if [[ -z "${AUTH_TOKEN:-}" ]]; then
  echo "ERROR: AUTH_TOKEN is not set in .env"
  exit 1
fi

BASE_URL="https://api-school.procareconnect.com/api/web/parent"

PHOTO_DIR="photos"
VIDEO_DIR="videos"
DELAY=0.5  # seconds between downloads to avoid rate-limiting

# Common headers (mirroring the original curl commands)
COMMON_HEADERS=(
  -H 'accept: application/json, text/plain, */*'
  -H 'accept-language: en-US,en;q=0.9'
  -H "authorization: $AUTH_TOKEN"
  -H 'dnt: 1'
  -H 'origin: https://schools.procareconnect.com'
  -H 'referer: https://schools.procareconnect.com/'
  -H 'sec-ch-ua: "Not:A-Brand";v="99", "Google Chrome";v="145", "Chromium";v="145"'
  -H 'sec-ch-ua-mobile: ?0'
  -H 'sec-ch-ua-platform: "macOS"'
  -H 'sec-fetch-dest: empty'
  -H 'sec-fetch-mode: cors'
  -H 'sec-fetch-site: same-site'
  -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36'
)

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in curl jq exiftool; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    if [[ "$cmd" == "exiftool" ]]; then
      echo "  Install with: brew install exiftool"
    elif [[ "$cmd" == "jq" ]]; then
      echo "  Install with: brew install jq"
    fi
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helper: sanitize caption for use as exiftool value
# ---------------------------------------------------------------------------
sanitize_caption() {
  # Replace literal \n with actual newlines, trim trailing whitespace
  echo -e "$1" | sed 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Helper: convert ISO date to exiftool format (YYYY:MM:DD HH:MM:SS)
# ---------------------------------------------------------------------------
iso_to_exif_date() {
  local iso_date="$1"
  # Extract date and time portions, ignoring timezone and fractional seconds
  # Input format: 2026-03-04T13:12:14.063-06:00
  local datetime
  datetime=$(echo "$iso_date" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}).*/\1:\2:\3 \4:\5:\6/')
  echo "$datetime"
}

# ---------------------------------------------------------------------------
# Helper: generate a filename-safe date prefix from ISO date
# ---------------------------------------------------------------------------
iso_to_filename_date() {
  local iso_date="$1"
  echo "$iso_date" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})T.*/\1-\2-\3/'
}

# ---------------------------------------------------------------------------
# Download & tag a single photo
# ---------------------------------------------------------------------------
download_photo() {
  local url="$1"
  local date_str="$2"
  local caption="$3"
  local id="$4"
  local output_path="$5"

  if [[ -f "$output_path" ]]; then
    echo "  ⏭  Already exists: $(basename "$output_path")"
    return 0
  fi

  echo "  ⬇  Downloading $(basename "$output_path") ..."
  if ! curl -sS -L --connect-timeout 30 --max-time 300 -o "$output_path" "$url"; then
    echo "  ❌  Failed to download $(basename "$output_path")"
    rm -f "$output_path"
    return 1
  fi

  # Verify we got an actual image (check for minimum file size)
  local filesize
  filesize=$(wc -c < "$output_path" | tr -d ' ')
  if [[ "$filesize" -lt 1000 ]]; then
    echo "  ⚠️  Suspicious file size ($filesize bytes), may not be a valid image"
  fi

  # Embed metadata
  local exif_date
  exif_date=$(iso_to_exif_date "$date_str")

  local exiftool_args=(
    -overwrite_original
    -q
    "-DateTimeOriginal=$exif_date"
    "-CreateDate=$exif_date"
    "-ModifyDate=$exif_date"
  )

  if [[ -n "$caption" ]]; then
    local clean_caption
    clean_caption=$(sanitize_caption "$caption")
    exiftool_args+=(
      "-IPTC:Caption-Abstract=$clean_caption"
      "-XMP:Description=$clean_caption"
      "-ImageDescription=$clean_caption"
    )
  fi

  exiftool_args+=("$output_path")
  exiftool "${exiftool_args[@]}" 2>/dev/null || echo "  ⚠️  exiftool warning for $(basename "$output_path")"

  echo "  ✅  $(basename "$output_path") — $exif_date"
}

# ---------------------------------------------------------------------------
# Download & tag a single video
# ---------------------------------------------------------------------------
download_video() {
  local url="$1"
  local date_str="$2"
  local caption="$3"
  local id="$4"
  local output_path="$5"

  if [[ -f "$output_path" ]]; then
    echo "  ⏭  Already exists: $(basename "$output_path")"
    return 0
  fi

  echo "  ⬇  Downloading $(basename "$output_path") ..."
  if ! curl -sS -L --connect-timeout 30 --max-time 300 -o "$output_path" "$url"; then
    echo "  ❌  Failed to download $(basename "$output_path")"
    rm -f "$output_path"
    return 1
  fi

  # Embed metadata
  local exif_date
  exif_date=$(iso_to_exif_date "$date_str")

  local exiftool_args=(
    -overwrite_original
    -q
    "-CreateDate=$exif_date"
    "-ModifyDate=$exif_date"
  )

  if [[ -n "$caption" ]]; then
    local clean_caption
    clean_caption=$(sanitize_caption "$caption")
    exiftool_args+=(
      "-XMP:Description=$clean_caption"
    )
  fi

  exiftool_args+=("$output_path")
  exiftool "${exiftool_args[@]}" 2>/dev/null || echo "  ⚠️  exiftool warning for $(basename "$output_path")"

  echo "  ✅  $(basename "$output_path") — $exif_date"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
echo "============================================="
echo " ProCare Connect Media Downloader"
echo "============================================="
echo ""

mkdir -p "$PHOTO_DIR" "$VIDEO_DIR"

# ---- PHOTOS ----
echo "📷 Fetching photo list..."

# URL-encode the date filters
PHOTO_URL="${BASE_URL}/photos/?page=1&filters%5Bphoto%5D%5Bdatetime_from%5D=$(echo "$PHOTO_DATE_FROM" | sed 's/ /%20/g')&filters%5Bphoto%5D%5Bdatetime_to%5D=$(echo "$PHOTO_DATE_TO" | sed 's/ /%20/g')"

# First request to get total count
first_page=$(curl -sS --connect-timeout 30 --max-time 60 "${COMMON_HEADERS[@]}" "$PHOTO_URL")
total_photos=$(echo "$first_page" | jq -r '.total')
per_page=$(echo "$first_page" | jq -r '.per_page')

if [[ "$total_photos" == "null" || -z "$total_photos" ]]; then
  echo "❌ Failed to fetch photo list. Check your auth token."
  echo "Response: $first_page"
  exit 1
fi

total_pages=$(( (total_photos + per_page - 1) / per_page ))
echo "   Found $total_photos photos across $total_pages pages ($per_page per page)"
echo ""

photo_counter=0
total_photo_count=0
prev_photo_date=""

for page in $(seq 1 "$total_pages"); do
  echo "📄 Page $page / $total_pages"

  if [[ "$page" -eq 1 ]]; then
    page_data="$first_page"
  else
    PAGE_URL="${BASE_URL}/photos/?page=${page}&filters%5Bphoto%5D%5Bdatetime_from%5D=$(echo "$PHOTO_DATE_FROM" | sed 's/ /%20/g')&filters%5Bphoto%5D%5Bdatetime_to%5D=$(echo "$PHOTO_DATE_TO" | sed 's/ /%20/g')"
    page_data=$(curl -sS --connect-timeout 30 --max-time 60 "${COMMON_HEADERS[@]}" "$PAGE_URL")
  fi

  num_items=$(echo "$page_data" | jq '.photos | length')

  for i in $(seq 0 $((num_items - 1))); do
    id=$(echo "$page_data" | jq -r ".photos[$i].id")
    caption=$(echo "$page_data" | jq -r ".photos[$i].caption // \"\"")
    date_str=$(echo "$page_data" | jq -r ".photos[$i].date")
    main_url=$(echo "$page_data" | jq -r ".photos[$i].main_url")

    date_prefix=$(iso_to_filename_date "$date_str")

    if [[ "$date_prefix" != "$prev_photo_date" ]]; then
      photo_counter=0
      prev_photo_date="$date_prefix"
    fi

    photo_counter=$((photo_counter + 1))
    total_photo_count=$((total_photo_count + 1))
    filename="${date_prefix}_$(printf '%04d' $photo_counter).jpg"
    output_path="${PHOTO_DIR}/${filename}"

    download_photo "$main_url" "$date_str" "$caption" "$id" "$output_path"
    sleep "$DELAY"
  done
done

echo ""
echo "📷 Photos complete: $total_photo_count downloaded"
echo ""

# ---- VIDEOS ----
echo "🎥 Fetching video list..."

VIDEO_URL="${BASE_URL}/videos/?page=1&filters%5Bvideo%5D%5Bdatetime_from%5D=$(echo "$VIDEO_DATE_FROM" | sed 's/ /%20/g')&filters%5Bvideo%5D%5Bdatetime_to%5D=$(echo "$VIDEO_DATE_TO" | sed 's/ /%20/g')"

first_video_page=$(curl -sS --connect-timeout 30 --max-time 60 "${COMMON_HEADERS[@]}" "$VIDEO_URL")
total_videos=$(echo "$first_video_page" | jq -r '.total')
videos_per_page=$(echo "$first_video_page" | jq -r '.per_page')

if [[ "$total_videos" == "null" || -z "$total_videos" ]]; then
  echo "❌ Failed to fetch video list. Check your auth token."
  echo "Response: $first_video_page"
  exit 1
fi

total_video_pages=$(( (total_videos + videos_per_page - 1) / videos_per_page ))
echo "   Found $total_videos videos across $total_video_pages pages ($videos_per_page per page)"
echo ""

total_video_count=0
video_counter=0
prev_video_date=""

for page in $(seq 1 "$total_video_pages"); do
  echo "📄 Video page $page / $total_video_pages"

  if [[ "$page" -eq 1 ]]; then
    page_data="$first_video_page"
  else
    PAGE_URL="${BASE_URL}/videos/?page=${page}&filters%5Bvideo%5D%5Bdatetime_from%5D=$(echo "$VIDEO_DATE_FROM" | sed 's/ /%20/g')&filters%5Bvideo%5D%5Bdatetime_to%5D=$(echo "$VIDEO_DATE_TO" | sed 's/ /%20/g')"
    page_data=$(curl -sS --connect-timeout 30 --max-time 60 "${COMMON_HEADERS[@]}" "$PAGE_URL")
  fi

  num_items=$(echo "$page_data" | jq '.videos | length')

  for i in $(seq 0 $((num_items - 1))); do
    id=$(echo "$page_data" | jq -r ".videos[$i].id")
    caption=$(echo "$page_data" | jq -r ".videos[$i].caption // \"\"")
    date_str=$(echo "$page_data" | jq -r ".videos[$i].date")
    video_url=$(echo "$page_data" | jq -r ".videos[$i].video_file_url")

    date_prefix=$(iso_to_filename_date "$date_str")

    if [[ "$date_prefix" != "$prev_video_date" ]]; then
      video_counter=0
      prev_video_date="$date_prefix"
    fi

    video_counter=$((video_counter + 1))
    total_video_count=$((total_video_count + 1))
    filename="${date_prefix}_$(printf '%04d' $video_counter).mp4"
    output_path="${VIDEO_DIR}/${filename}"

    download_video "$video_url" "$date_str" "$caption" "$id" "$output_path"
    sleep "$DELAY"
  done
done

echo ""
echo "🎥 Videos complete: $total_video_count downloaded"
echo ""
echo "============================================="
echo " All done!"
echo " Photos: ./$PHOTO_DIR/ ($total_photo_count files)"
echo " Videos: ./$VIDEO_DIR/ ($total_video_count files)"
echo "============================================="
