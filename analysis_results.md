# ProCare Media Downloader — Analysis & Recommendations

## Project Overview

A bash script that downloads photos and videos from the ProCare Connect daycare parent portal API, embedding EXIF/XMP date and caption metadata via `exiftool`. Currently **534 photos** and **7 videos** have been downloaded.

The script is well-structured with good foundations (idempotent, rate-limited, metadata embedding, dependency checks). The recommendations below are grouped by category and ordered by impact.

---

## 🚀 Efficiency Improvements

### 1. Parallel Downloads (High Impact)

Currently each file downloads sequentially with a 0.5s delay. With 534+ photos, that's **~4.5 minutes** of idle delay time alone.

**Recommendation:** Use `xargs -P` or GNU `parallel` for concurrent downloads (e.g. 4–6 at a time), keeping the aggregate rate under API limits.

```bash
# Example: download up to 4 files concurrently
echo "$download_list" | xargs -P 4 -I {} bash -c 'download_photo "$@"' _ {}
```

**Estimated time savings:** 60–75% faster for large libraries.

---

### 2. Batch Exiftool Processing (High Impact)

`exiftool` has significant per-invocation startup overhead (~0.2s). The script currently calls it once per file (534+ times).

**Recommendation:** Collect all metadata operations and run a single `exiftool` call with an argfile at the end of each media type:

```bash
# Build argfile during download loop
echo "-DateTimeOriginal=$exif_date" >> "$ARGFILE"
echo "-CreateDate=$exif_date" >> "$ARGFILE"
echo "$output_path" >> "$ARGFILE"
echo "-execute" >> "$ARGFILE"

# Single call at the end
exiftool -@ "$ARGFILE" -overwrite_original -q
```

**Estimated speedup:** ~100s saved on 534 files.

---

### 3. Smarter Skip Logic — Check File Integrity (Medium Impact)

The current "already exists" check only tests `[[ -f "$output_path" ]]`. A file that was partially downloaded (e.g. interrupted run, network timeout) will pass this check but be corrupt.

**Recommendation:** Store a download manifest (JSON or TSV) that records each file's expected size or checksum. On re-run, verify via `Content-Length` header comparison:

```bash
# Quick HEAD request to get expected size (no full download)
expected_size=$(curl -sI "$url" | grep -i content-length | awk '{print $2}' | tr -d '\r')
actual_size=$(wc -c < "$output_path" | tr -d ' ')
if [[ "$actual_size" -eq "$expected_size" ]]; then
  echo "  ⏭  Verified: $(basename "$output_path")"
  return 0
fi
```

---

### 4. Pre-validate Auth Token (Low Effort, High UX)

The script doesn't discover an expired token until it tries to fetch the first page — and then only shows the raw JSON error.

**Recommendation:** Add an upfront token validation call before entering the download loops:

```bash
validate_token() {
  local resp
  resp=$(curl -sS --connect-timeout 10 "${COMMON_HEADERS[@]}" "${BASE_URL}/photos/?page=1")
  if echo "$resp" | jq -e '.error' &>/dev/null; then
    echo "❌ Auth token is expired or invalid."
    echo "   Get a new one from browser DevTools → Network → authorization header."
    exit 1
  fi
}
```

---

## 🎯 User-Friendliness Improvements

### 5. Progress Bar / ETA Display (High Impact)

With 500+ files, the user has no sense of progress. The current output is a wall of `✅` lines.

**Recommendation:** Add a compact progress counter:

```
📷 Downloading photos [147/534] 28% ━━━━━━━━░░░░░░░░░░░░ ETA: 3m12s
```

This can be done with `printf '\r...'` (carriage return) for in-place updates, or with a simple counter display:

```bash
echo "  [$total_photo_count/$total_photos] ✅ $(basename "$output_path")"
```

---

### 6. CLI Arguments for Date Range (Medium Impact)

Currently, editing `.env` is the only way to change the date range. This is friction for a common operation.

**Recommendation:** Accept optional CLI flags that override `.env` values:

```bash
bash download_media.sh --from "2026-03-01" --to "2026-04-05"
bash download_media.sh --photos-only
bash download_media.sh --videos-only
```

This also enables cron/automation use cases without modifying `.env`.

---

### 7. Organize Into Date Subdirectories (Medium Impact)

Currently all 534 photos dump into a flat `photos/` folder. This becomes unwieldy to browse.

**Recommendation:** Add an option (or make it default) to organize by `YYYY/MM` or `YYYY-MM-DD` subdirectories:

```
photos/
├── 2025-08/
│   ├── 2025-08-19_03152305.jpg
│   └── ...
├── 2025-09/
│   ├── 2025-09-05_1c359ba8.jpg
│   └── ...
```

```bash
date_dir="${PHOTO_DIR}/${date_str:0:7}"  # YYYY-MM
mkdir -p "$date_dir"
output_path="${date_dir}/${filename}"
```

---

### 8. Download Summary Log (Low Effort)

After completion, the script only prints totals. There's no persistent record.

**Recommendation:** Write a `download_log.txt` with timestamps, counts, and any errors:

```
[2026-04-05 09:00:41] Run started
[2026-04-05 09:00:41] Photos: 534 total, 12 new, 522 skipped, 0 failed
[2026-04-05 09:02:15] Videos: 7 total, 0 new, 7 skipped, 0 failed
[2026-04-05 09:02:15] Run completed in 1m34s
```

---

### 9. Colored & Structured Terminal Output (Low Effort)

The emoji usage is good, but adding ANSI colors and section separators would improve scannability:

```bash
GREEN='\033[0;32m'  RED='\033[0;31m'  YELLOW='\033[1;33m'  NC='\033[0m'
echo -e "${GREEN}✅ Downloaded${NC} photo_001.jpg"
echo -e "${RED}❌ Failed${NC} photo_002.jpg"
echo -e "${YELLOW}⏭  Skipped${NC} photo_003.jpg (already exists)"
```

---

## 🔒 Robustness Improvements

### 10. Retry with Exponential Backoff (High Impact)

Currently, a failed download is logged and skipped. On re-run, it won't retry because the file doesn't exist (the `rm -f` on failure correctly handles this). But transient network errors could cause many failures in a single run.

**Recommendation:** Add retry logic (3 attempts with backoff):

```bash
download_with_retry() {
  local url="$1" output="$2" max_retries=3
  for attempt in $(seq 1 "$max_retries"); do
    if curl -sS -L --connect-timeout 30 --max-time 300 -o "$output" "$url"; then
      return 0
    fi
    echo "  ⚠️  Attempt $attempt/$max_retries failed, retrying in $((attempt * 2))s..."
    sleep $((attempt * 2))
  done
  rm -f "$output"
  return 1
}
```

---

### 11. Graceful Interrupt Handling (Medium Impact)

If the user hits `Ctrl+C` mid-download, `set -e` causes immediate exit, potentially leaving a partial file on disk. The next run would skip it (thinking it's complete).

**Recommendation:** Trap `SIGINT`/`SIGTERM` to clean up:

```bash
CURRENT_DOWNLOAD=""
cleanup() {
  if [[ -n "$CURRENT_DOWNLOAD" && -f "$CURRENT_DOWNLOAD" ]]; then
    echo ""
    echo "⚠️  Interrupted! Cleaning up partial download: $CURRENT_DOWNLOAD"
    rm -f "$CURRENT_DOWNLOAD"
  fi
  exit 130
}
trap cleanup SIGINT SIGTERM
```

---

### 12. Rate-Limit Response Detection (Low Effort)

The 0.5s delay is a guess. If the API returns a 429 (Too Many Requests), the script should detect it and back off automatically.

**Recommendation:** Check HTTP status codes on download responses:

```bash
http_code=$(curl -sS -L -w '%{http_code}' --connect-timeout 30 --max-time 300 -o "$output_path" "$url")
if [[ "$http_code" == "429" ]]; then
  echo "  ⏳ Rate limited, backing off 10s..."
  sleep 10
  # retry
fi
```

---

## 🧹 Code Quality Improvements

### 13. DRY: Unify Photo/Video Download Logic (Medium Impact)

`download_photo()` and `download_video()` are ~90% identical. The only differences are: photos set `DateTimeOriginal` and IPTC fields, videos don't.

**Recommendation:** Refactor into a single `download_media()` function with a `type` parameter:

```bash
download_media() {
  local type="$1"  # "photo" or "video"
  local url="$2" date_str="$3" caption="$4" id="$5" output_path="$6"
  # ... shared download + verification logic ...
  
  local exiftool_args=(-overwrite_original -q "-CreateDate=$exif_date" "-ModifyDate=$exif_date")
  if [[ "$type" == "photo" ]]; then
    exiftool_args+=("-DateTimeOriginal=$exif_date")
  fi
  # ... shared caption logic ...
}
```

This eliminates ~50 lines of duplication.

---

### 14. Unify URL Construction (Low Effort)

The photo and video URL construction is duplicated and fragile (manual `sed` for URL encoding).

**Recommendation:** Extract a helper function:

```bash
build_api_url() {
  local media_type="$1" page="$2" date_from="$3" date_to="$4"
  local encoded_from encoded_to
  encoded_from=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$date_from'))")
  encoded_to=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$date_to'))")
  echo "${BASE_URL}/${media_type}/?page=${page}&filters%5B${media_type%s}%5D%5Bdatetime_from%5D=${encoded_from}&filters%5B${media_type%s}%5D%5Bdatetime_to%5D=${encoded_to}"
}
```

---

## 📋 Priority Summary

| # | Recommendation | Effort | Impact | Category |
|---|----------------|--------|--------|----------|
| 1 | Parallel downloads | Medium | ⭐⭐⭐ | Efficiency |
| 2 | Batch exiftool | Medium | ⭐⭐⭐ | Efficiency |
| 3 | File integrity checks | Medium | ⭐⭐ | Efficiency |
| 4 | Pre-validate auth token | Low | ⭐⭐⭐ | UX |
| 5 | Progress bar / ETA | Low | ⭐⭐⭐ | UX |
| 6 | CLI argument overrides | Medium | ⭐⭐ | UX |
| 7 | Date subdirectories | Low | ⭐⭐ | UX |
| 8 | Download summary log | Low | ⭐⭐ | UX |
| 9 | Colored terminal output | Low | ⭐ | UX |
| 10 | Retry with backoff | Low | ⭐⭐⭐ | Robustness |
| 11 | Graceful Ctrl+C handling | Low | ⭐⭐ | Robustness |
| 12 | Rate-limit detection | Low | ⭐⭐ | Robustness |
| 13 | DRY refactor (photo/video) | Medium | ⭐⭐ | Code quality |
| 14 | Unified URL construction | Low | ⭐ | Code quality |

---

## 💡 Quick Wins (implement all in < 30 min)

If you want the biggest bang for the least effort, I'd start with:
1. **#4** — Pre-validate auth token (saves debugging headaches)
2. **#5** — Progress counter (sanity during long runs)
3. **#10** — Retry logic (network resilience)
4. **#11** — Graceful Ctrl+C (prevents corrupt files)
5. **#9** — Colored output (polish)

Let me know which recommendations you'd like me to implement!
