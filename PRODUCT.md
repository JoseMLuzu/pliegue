# Pliegue · Native Mac Microapp

## Product direction

A small desktop utility with a **USD 4.99 one-time purchase**, no app account, subscription, ads, custom license keys, or usage credits. Regional prices will be configured in App Store Connect. No pricing, listing, or commercial agreement has been configured.

Users purchase and download through the Mac App Store. Pliegue itself requires no login. Compression runs locally without an internet connection.

## First version

- Native Swift and SwiftUI macOS app, opened with a double click.
- One window: add files, choose mode and quality, compress, review sizes, and save.
- Convert supported static photos to verified lossless PNG or explicitly lossy JPEG, preserving dimensions and orientation.
- Re-encode supported SDR video in HEVC with high visual quality while preserving resolution and orientation, clearly disclosing that video has loss.
- Convert supported audio to verified lossless ALAC or explicitly lossy AAC, preserving sample rate and channel count.
- Optimize self-contained GLB files without altering geometry or textures; archive other model formats and project folders with their included assets.
- Create verified lossless ZIP archives for any regular file type or folder, without promising savings for already compressed formats.
- Show actual sizes; discard optimized media or GLB results that are not smaller.
- Provide progress, cancellation, native file panels, shortcuts, and protection against replacing input files.
- Require no server, terminal commands, Python, FFmpeg, downloaded encoder, or third-party runtime SDK.

The one-time purchase enables this version without usage credits. Technical format, disk, memory, and processing limits remain. No promise is made that perpetual support or every future major version is included.

## Implementation

ImageIO handles photos, AVFoundation and Core Audio handle media, CryptoKit verifies data, and system zlib provides streaming ZIP64. A bounded GLB parser removes JSON whitespace while copying binary payloads exactly. The browser/Python implementation is archived in `legacy/` and excluded from native builds.

The native app does not distribute the GPL-enabled FFmpeg from the prototype. Native codec support is limited; unsupported files remain eligible for lossless ZIP. Specialized media processing is single-file; multiple selections use ZIP. See [format limits](docs/FORMATS.md).

## Distribution work still required

Validate native image/audio/video and sandbox workflows on physical Macs, register the final bundle identifier and Apple Developer team, configure distribution signing, finalize artwork and privacy/support URLs, configure the paid listing, and submit to App Review. A development build is not an approved store release.

## Outside the first version

Accounts, cloud processing, synchronization, ads, recurring billing, iPhone/iPad releases, batch media transcoding, mesh decimation, video editing, and promises to reduce every file without any quality loss.
