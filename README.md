# MotionPhotoConverter

Batch convert Google / Samsung Motion Photos into Apple Live Photos.

Motion Photos from Android phones embed an MP4 video inside a JPEG or HEIC file. This tool extracts the video, preserves the original capture timestamp, and generates a Live Photo that works in the Apple Photos app.

## Features

- Extracts MP4 from Google and Samsung Motion Photo files (`.jpg`, `.jpeg`, `.heic`)
- Three-strategy video detection: XMP metadata → `MotionPhoto_Data` marker → `mpvd` marker
- Preserves EXIF capture date as the Live Photo timestamp
- Video pass-through (no re-encoding) — zero quality loss
- Output as paired `.jpg` + `.mov` files, or save directly to Photos library

## Requirements

- macOS 10.15+
- Swift 6.0+

## Install

```bash
git clone --recurse-submodules git@github.com:MirageTurtle/MotionPhotoConverter.git
cd MotionPhotoConverter
swift build -c release
```

## Usage

```bash
# Export paired resources to a directory
.build/release/MotionPhotoConverter --input ~/photos/motion-photos --output ~/photos/live-photos

# Save directly to Photos library
.build/release/MotionPhotoConverter --input ~/photos/motion-photos
```

| Argument | Required | Description |
|----------|----------|-------------|
| `--input`, `-i` | Yes | Directory containing Motion Photo files |
| `--output`, `-o` | No | Output directory (if omitted, saves to Photos library) |

## Example

```bash
# Process vacation photos
.build/release/MotionPhotoConverter --input ~/Pictures/Xinjiang --output ~/Pictures/Xinjiang_live

# Output
Processing 1800 files...
[1/1800] PXL_20260621_105003.jpg ... saved to /Users/me/Pictures/Xinjiang_live
[2/1800] PXL_20260618_213549.jpg ... saved to /Users/me/Pictures/Xinjiang_live
...
Done. 1790 succeeded, 10 skipped, 0 failed.
```

## Output

Each Motion Photo produces two files with the same base name:

```
PXL_20260621_105003.jpg   (key photo)
PXL_20260621_105003.mov   (paired video)
```

These can be imported into Apple Photos or any app that supports Live Photos.

## How It Works

1. **Extract** MP4 video from the JPEG/HEIC container using XMP metadata or byte markers
2. **Read** EXIF `DateTimeOriginal` from the image for the correct timestamp
3. **Remux** the video into MOV with content identifier and still-image-time metadata
4. **Copy** the JPEG with asset identifier linking it to the paired video
5. **Save** as a Live Photo (paired resources or Photos library import)

## Credits

Built on [LivePhoto.swift](https://github.com/MirageTurtle/LivePhoto) by Alexander Pagliaro / Limit Point LLC.

MP4 extraction logic inspired by [motion-photo-extractor](https://github.com/ikerls/motion-photo-extractor).
