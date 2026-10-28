# Architecture

## Interface and work

The SwiftUI app owns a main-actor `CompressionModel`. A native NavigationSplitView contains the category sidebar, file table, unified toolbar, and collapsible grouped-form inspector. SwiftUI's system file importer presents separate file and folder selection workflows; NSSavePanel handles saving. Security-scoped input access remains active while a file is selected. Compression and saving run in detached tasks; progress uses operation identifiers to reject stale updates. A lock-protected token provides cooperative cancellation.

Single files select a mode from their extension; multiple selections and folders default to ZIP. Changing mode, quality, or fidelity invalidates the previous result. Photos and audio default to lossless. `CompressionService` routes work to dedicated engines; all operate locally and retain originals.

## Images

ImageIO decodes and encodes static images. Lossless output and images with alpha use PNG; opaque high-quality output uses JPEG. A second decode checks dimensions and orientation. Lossless verification compares bit depth, ICC profile, and SHA-256 of canonical rendered RGBA8 pixels. Multi-page and detected auxiliary images are rejected rather than flattened. A 64-megapixel bound limits decoded memory, but large photos still require substantial RAM. A system image encode cannot be interrupted internally; cancellation is checked before and after it.

## Audio

AVAudioFile decodes in 16,384-frame Float32 planar blocks. Supported lossless inputs are encoded as ALAC; high-quality mono/stereo audio uses AAC. Core Audio's independently enumerated encoder list gates unavailable codecs. Sample rate and channel count are retained. Output is decoded fully, checking frame count (with AAC padding tolerance); ALAC additionally compares per-channel decoded-sample SHA-256 hashes. Unsupported floating-point/high-depth lossless inputs are rejected. Re-encoding may alter metadata.

## Video

AVAssetReader decodes video to YUV samples, which AVAssetWriter encodes as HEVC at a quality-dependent bitrate. Audio is passed through without decoding or re-encoding; payload hashes are accumulated during copying. The pump services tracks in turn, observes backpressure, checks cancellation, and aborts on errors or stalls. Non-Sendable AVFoundation objects remain owned by the operation.

A second reader decodes every output frame and checks frame count, resolution, transform, and duration. Separate readers compare output audio SHA-256 hashes. A result that is not smaller is discarded. HDR, incompatible formats, and extra tracks are rejected.

Marker-only sample buffers contain zero media samples and are excluded from payload hashing and frame counting. Nonempty audio buffers without data are still rejected. Each output audio track must also retain its source presentation start and duration within 5 ms. A real AAC edit-list sample exposed a timing mismatch despite matching payload hashes; that case is now rejected rather than accepted. See [real-file validation](REAL-FILE-VALIDATION.md).

## ZIP

`ArchivePlanner` expands selected directories into regular files and directory markers, preserving internal paths, hidden files, and empty folders. Symlinks and unreadable entries abort the selection; total entries are bounded to 10,000. Root names are normalized and disambiguated; internal path components remain exact so linked assets survive extraction.

The streaming writer emits raw DEFLATE, UTF-8 names, ZIP64 local headers, central directory, and end records. ZIP64 fields are used even for small files, avoiding a layout change at 4 GiB. Buffers are bounded to 1 MiB.

Input size and modification date are checked for changes. Each input is hashed while reading. After writing, every data region is inflated and hashed again. Independent macOS extraction tests also check serialized ZIP structure.

## 3D models

`ModelCompressor` validates GLB 2.0 headers and chunk boundaries, then lexically removes JSON whitespace outside strings. It preserves number spellings and escaped strings, pads JSON to four-byte alignment, and updates the header length. Binary and unknown chunks are copied in bounded buffers and hashed, with JSON-token and output-tail verification. External URIs require a project ZIP. Non-GLB models and folders route through the archive engine without geometry changes.

## Saving and cleanup

Results are temporary until saved. Destinations matching input paths or file identifiers are rejected, including symbolic-link resolution and hard links. Saving inside any selected source folder is also rejected. A complete copy is staged on the destination volume, then moved or atomically replaced. Cancellation preserves an existing destination. Media and GLB outputs with no savings are discarded; ZIP results remain available for grouping files.

Failure or cancellation removes an operation's workspace. Clearing a result removes its workspace. Normal termination waits for cancellation and removes the result. Crashes or force-quits can leave temporary files; originals never belong to a workspace.

## Sandbox

Only App Sandbox and user-selected read/write access are requested. There are no network, camera, microphone, or full-disk entitlements, and no third-party runtime dependencies. The privacy manifest declares no collection or tracking, and file metadata access for selected files and app-container files. The final release requires physical-device tests and a privacy/API audit.
