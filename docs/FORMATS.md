# Formats and Fidelity

Pliegue offers specialized processing for supported media and verified ZIP for general files. A supported filename extension does not guarantee the codecs or features inside it can be processed. The app reports unsupported inputs and leaves originals untouched.

| Mode | Inputs | Output | Preservation |
| --- | --- | --- | --- |
| Photos · Lossless | Static JPEG, PNG, HEIC/HEIF, TIFF, BMP supported by ImageIO | PNG | Verified decoded pixels, color profile, dimensions, orientation, and transparency; metadata may change |
| Photos · High quality | Same static images | JPEG for opaque images; PNG for transparency | JPEG has loss; dimensions and orientation checked |
| Video | Supported SDR MP4, MOV, M4V | HEVC MP4 or MOV | Video has loss; resolution/orientation retained; audio payloads copied and hashed |
| Audio · Lossless | Supported integer PCM up to 24-bit, FLAC, ALAC in readable containers | ALAC M4A | Decoded samples verified; sample rate/channels retained; metadata may change |
| Audio · High quality | Supported WAV, AIFF, FLAC, M4A, MP3, AAC, CAF | AAC M4A | Audio has loss; sample rate/channels retained; mono or stereo only |
| 3D models · GLB | Self-contained GLB 2.0 | GLB | Removes JSON whitespace; preserves exact number/string tokens and all remaining chunks |
| 3D models · Other | OBJ, FBX, STL, BLEND, glTF, PLY, DAE, USD family, 3MF, project folders | ZIP | Exact included file contents and internal paths; no geometry or texture conversion |
| Any file · ZIP | Regular files and folders of any type | ZIP64 | Exact file contents; filesystem attributes are limited |

Photos and audio default to lossless. High quality is an explicit lossy choice. Video processing is always lossy; use ZIP when the original video bytes must remain exact. Identical decoded pixels or audio samples do not imply an identical original file or metadata.

## Limits

- Media processing handles one file at a time. Multiple files and folders use ZIP; they are not batch-transcoded.
- Photos are limited to one static image and 64 megapixels. Lossless pixel verification supports up to 8 bits per component. Animated, multi-page, or detected HDR/depth/portrait auxiliary images require ZIP.
- Audio requires a native macOS decoder and the requested ALAC/AAC encoder. Lossless processing rejects floating-point PCM, PCM above 24-bit, and lossy compressed sources. ALAC allows up to eight channels; AAC currently allows one or two without downmixing.
- Video requires an available native HEVC encoder. HDR/Dolby Vision, multiple video tracks, subtitles, timed metadata, and incompatible passthrough tracks are rejected. Output frames and copied audio are verified; this does not measure perceptual quality.
- Video output is also rejected if an audio track's presentation start or duration changes by 5 ms or more. Some AAC priming/edit-list combinations currently remain unsupported; see [measured real-file results](REAL-FILE-VALIDATION.md).
- GLB optimization accepts a first JSON chunk up to 32 MiB, validates chunk boundaries, and streams remaining chunks. External asset URIs require selecting a complete project folder for ZIP. GLB optimization does not apply Draco, meshopt, decimation, or texture recompression. Compact GLBs may have no removable space.
- ZIP accepts at most 10,000 entries including directory markers, preserves empty folders and hidden files, and rejects symbolic links. Only included assets are archived; external references are not located or rewritten. Keep the source folder unchanged while processing.
- ZIP preserves internal folder names exactly. Selected root names may be normalized or disambiguated. Owners, Finder tags, extended attributes, and original permissions are not preserved. Save outside selected source folders.

Media and GLB outputs that are not smaller are discarded. ZIP can be larger due to archive overhead. Already compressed JPEG, HEIC, MP4, AAC, GLB, ZIP, and similar files often have little room for further lossless savings.
