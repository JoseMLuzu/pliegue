# Pliegue

A small, native macOS compression app for **photos, video, audio, 3D models, and general files or folders**, built with Swift, SwiftUI, ImageIO, AVFoundation, CryptoKit, and system zlib. No account, ads, subscription, local web server, Python installation, or FFmpeg dependency is required by the native app.

The product direction is a **USD 4.99 one-time purchase** on the Mac App Store. This repository builds a local development app; no store listing, purchase, or distribution signing has been configured. See [PRODUCT.md](PRODUCT.md).

## Requirements

- macOS 14 or later.
- Xcode 15.3 or later, or a compatible Swift toolchain with the macOS SDK, to build from source.
- Access to Apple's HEVC encoder for video, or AAC/ALAC encoders for audio. Availability depends on the Mac and execution environment; ZIP does not require media encoders.

All new source identifiers, comments, documentation, and native interface text are in English.

## Build and open

Open **Pliegue.xcodeproj**, choose the **Pliegue** scheme, and run. The app target compiles the same core source files tested by the Swift package, with no package resolution or remote dependencies. Local signing is configured; distribution signing is a separate step.

Alternatively:

```sh
./scripts/build-app.sh
open dist/Pliegue.app
```

The build script generates the icon and an ad-hoc-signed, sandboxed `dist/Pliegue.app` for the current Mac architecture. It does not install or publish anything. Distribution requires proper signing and packaging.

For restricted development environments that cannot run SwiftPM's nested sandbox or `dsymutil`:

```sh
./scripts/build-app.sh --disable-sandbox --build-system native -debug-info-format none
```

These options apply only to build tools; the app retains its App Sandbox entitlements. The `native` SwiftPM engine is deprecated in recent toolchains and is a compatibility workaround. Prefer the normal build or Xcode elsewhere.

## Use

1. Add files or a folder with the native file picker or drag and drop.
2. A single supported file selects **Photos**, **Video**, **Audio**, or **3D models** automatically. Multiple files and folders select **Files & Folders** (ZIP) in the sidebar.
3. Choose fidelity and quality when available, then start. Photos and audio default to **Lossless**; **High quality · lossy** trades fidelity for savings.
4. Review actual sizes and save with the native save panel.

**Command-O** adds files, **Shift-Command-O** adds folders, **Command-Return** compresses, **Command-period** cancels, and **Command-S** saves. Select table rows and use Remove or Delete to remove them from the list without deleting their sources. The toolbar can hide or show the compression inspector. Normal app termination cancels work, waits for it to stop, and clears its temporary result.

Media processing handles one file at a time. Multiple selections are archived together, rather than individually re-encoded. See the complete [format and fidelity guide](docs/FORMATS.md).

### Photos

- Accepts one static JPEG, PNG, HEIC/HEIF, TIFF, or BMP supported by macOS, up to 64 megapixels.
- Lossless mode writes PNG and checks decoded pixels, color profile, dimensions, and orientation. Pixel verification supports up to 8 bits per component.
- High quality writes JPEG for opaque images, with explicit quality loss. Images with transparency always use PNG.
- Animated, multi-page, and detected HDR/depth auxiliary images are rejected; ZIP preserves their original contents instead. Some metadata may change during image conversion.

### Video

- Accepts one SDR **MP4, MOV, or M4V** at a time, using formats supported by macOS.
- Re-encodes the image to **HEVC/H.265**, without resizing or changing orientation. Video has loss: preserving resolution does not guarantee identical or imperceptibly different quality.
- **More savings**, **High quality**, and **More detail** use different target bitrate policies based on source bitrate, dimensions, and frame rate. Actual size and speed depend on the media and Mac.
- Copies audio without re-encoding and verifies each track's payload using SHA-256.
- Checks each audio track's start time and duration. Some AAC trim/edit-list combinations currently fail this check and are rejected; use ZIP for those clips. See [real-file validation](docs/REAL-FILE-VALIDATION.md).
- Decodes every output video frame and checks frame count, dimensions, orientation, and duration before accepting the result. This verifies integrity, not perceptual quality.
- Produces MP4 for compatible AAC/MP3/ALAC audio, or MOV for other supported passthrough audio.
- Discards recoded files that are not smaller, retaining the original. Input files are never overwritten.
- Rejects HDR/Dolby Vision, multiple video tracks, subtitle/timed-metadata tracks, and incompatible media rather than silently dropping tracks. Some static metadata may change. HEVC playback support is required.

### Audio

- Accepts one supported WAV, AIFF, FLAC, M4A, MP3, AAC, or CAF file.
- Lossless mode writes ALAC in M4A for supported integer PCM up to 24-bit, FLAC, and ALAC sources. Decoded samples are compared with SHA-256.
- High quality writes AAC in M4A with loss, for mono or stereo. Sample rate and channel count remain unchanged.
- Floating-point audio and unsupported lossless sources use ZIP for exact preservation. Metadata may change during audio conversion.
- The entire output is decoded to verify duration and format. Missing native encoders produce an error and leave the source untouched.

### 3D models

- Self-contained GLB 2.0 files can be optimized by removing JSON whitespace. Number tokens, geometry, animation, and binary texture data remain unchanged and are verified.
- This is conservative optimization: already compact GLBs may have no savings. No mesh decimation or texture recompression is performed.
- OBJ, FBX, STL, BLEND, glTF, USD, and other model files use verified ZIP. Select a whole project folder to include textures and other linked assets. Internal paths and empty folders are preserved; references outside the selection are not collected.

### Any file · ZIP

- Accepts files and folders, up to **10,000 total archive entries**, including empty files, empty folders, hidden files, and unknown file types.
- Implements raw DEFLATE and ZIP64 using system zlib, with bounded 1 MiB buffers.
- Verifies every decompressed entry against the original SHA-256.
- Preserves file contents, relative folder paths, and ZIP-compatible modification times. Duplicate selected root names are numbered and incompatible root-name characters normalized. Internal names remain exact to preserve project links. Filesystem owners, extended attributes, Finder tags, and original permissions are not preserved.
- Does not guarantee savings. JPG, MP4, ZIP, and other compressed formats can produce a larger archive; the app reports this explicitly.
- Symbolic links are rejected instead of followed. Save the archive outside selected source folders.

Photos, audio, video, and GLB optimization discard results that are not smaller and retain the original. ZIP remains available to group files even when its overhead makes the result larger. No mode guarantees savings for every source.

## Test

```sh
swift test
```

In this restricted development environment:

```sh
swift test --disable-sandbox --cache-path .build/cache \
  --config-path .build/config --security-path .build/security
```

Tests cover independently extracted ZIP64 archives, folder hierarchy and linked model assets, image pixel and transparency checks, JPEG output, GLB token and binary preservation, cancellation, source changes, and safe saving. Native audio/video integration tests use generated or checked-in synthetic media; no network or FFmpeg is needed at test time. Encoder integration tests explicitly skip when independent system capability checks fail. A skip does not count as successful codec verification. See [local validation](docs/VALIDATION.md).

## Layout

```text
Pliegue.xcodeproj/          Native app target and shared scheme
Package.swift              Swift package with no external dependencies
Sources/PliegueApp/         SwiftUI window, file panels, app lifecycle
Sources/PliegueCore/        Image, video, audio, GLB, ZIP64, safe saving
Tests/PliegueCoreTests/     Tests and synthetic media fixtures
Resources/                 Metadata, icon, sandbox and privacy manifest
scripts/                   App bundle and icon generation
docs/                      Architecture, privacy, release preparation
legacy/                    Archived Python/FFmpeg/browser prototype
dist/Pliegue.app            Generated development app, ignored by Git
```

The old `.tools/ffmpeg` binary, if present, is only for the legacy prototype or fixture generation. It is **not linked, launched, or bundled** by the native app.

## Data and release status

Files stay on the Mac. The app has no network entitlement, account service, analytics SDK, or advertising SDK. Results remain temporary until saved. Saving stages a complete file before replacing a chosen output, so cancellation does not destroy an existing destination. Crashes and force-quits may leave temporary files for operating-system cleanup.

See [privacy](docs/PRIVACY.md), [architecture](docs/ARCHITECTURE.md), and [release preparation](docs/RELEASE.md). Native codecs and sandbox file workflows must be tested on physical Macs before release. The local app is not a Mac App Store submission.

The native workspace layout, colors, result states, and accessibility behavior are described in [interface design](docs/DESIGN.md).
