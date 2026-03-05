# ProCare Connect Media Downloader

Downloads all photos and videos from the ProCare Connect parent portal, saving them locally with embedded date and caption metadata.

## Prerequisites

Install via [Homebrew](https://brew.sh):

```bash
brew install jq exiftool
```

(`curl` is included with macOS.)

## Setup

1. Copy the example config and fill in your values:

   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with a current auth token and the date range you want:

   ```
   AUTH_TOKEN="Bearer online_auth_..."
   PHOTO_DATE_FROM="2025-08-01 00:00"
   PHOTO_DATE_TO="2026-03-31 23:59"
   VIDEO_DATE_FROM="2025-09-01 00:00"
   VIDEO_DATE_TO="2026-03-31 23:59"
   ```

   > **Getting a token:** Log into [schools.procareconnect.com](https://schools.procareconnect.com), open browser DevTools → Network tab, navigate to Photos, and copy the `authorization` header from any API request.

## Usage

```bash
bash download_media.sh
```

The script is **idempotent** — re-running it skips files that already exist. A 0.5 s delay between downloads avoids rate-limiting.

## Output

| Folder    | Contents                                 |
| --------- | ---------------------------------------- |
| `photos/` | JPGs named `YYYY-MM-DD_NNNN.jpg`        |
| `videos/` | MP4s named `YYYY-MM-DD_NNNN.mp4`        |

Each file has EXIF/XMP metadata embedded:

- **Photos:** `DateTimeOriginal`, `CreateDate`, IPTC `Caption-Abstract`, XMP `Description`
- **Videos:** `CreateDate`, XMP `Description`
