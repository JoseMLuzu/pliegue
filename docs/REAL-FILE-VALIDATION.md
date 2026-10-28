# Real File Validation · 2026-10-27

## Result

The native compression engine completed **21 cases** in a LaunchServices app signed with the same App Sandbox and user-selected read/write entitlements as Pliegue. There was no FFmpeg encoding fallback: every result came from the app's actual `CompressionService` and `ResultSaver`.

- 14 cases produced smaller accepted outputs.
- Five retained their already compact originals.
- One ZIP was valid but 76 bytes larger; it remained available for grouping files.
- One MP4 was rejected because its audio presentation timing changed. It is an unresolved supported-format limitation, not a passing video test.
- All 20 non-error cases passed independent validation. Every selected source's SHA-256 remained unchanged, including the rejected case.

These are a small compatibility sample, not a guarantee of savings or compatibility for all files. Eighteen cases use public/system/repository content or explicitly described derivatives; three additional video cases use synthetic regression fixtures.

## Measurements

Sizes below are exact bytes. Negative savings means a larger ZIP. Photo/video/AAC re-encoding can have loss where selected; PNG/ALAC preservation is checked against the decoded input.

| Case | Status | Original bytes | Output bytes | Savings | Originals unchanged |
| --- | --- | ---: | ---: | ---: | --- |
| photo-jpeg-lossless | retained | 18122 | 18122 | 0.00% | Yes |
| photo-jpeg-high-quality | retained | 18122 | 18122 | 0.00% | Yes |
| photo-tiff-lossless | compressed | 334100 | 185205 | 44.57% | Yes |
| audio-wav-alac | compressed | 365970 | 143373 | 60.82% | Yes |
| audio-wav-aac | compressed | 365970 | 95305 | 73.96% | Yes |
| audio-aiff-alac | compressed | 304344 | 154742 | 49.16% | Yes |
| audio-mp3-aac | retained | 39868 | 39868 | 0.00% | Yes |
| video-flower-hevc | error | 1128375 | — | — | Yes |
| model-glb | retained | 3773916 | 3773916 | 0.00% | Yes |
| model-project-zip | compressed | 3775556 | 3378916 | 10.51% | Yes |
| documents-zip | compressed | 24489 | 10009 | 59.13% | Yes |
| compressed-video-zip | compressed | 1128375 | 967066 | 14.30% | Yes |
| compressed-photo-zip | archive-no-savings | 18122 | 18198 | -0.42% | Yes |
| mixed-files-zip | compressed | 4960281 | 4402945 | 11.24% | Yes |
| photo-jpeg-smaller | retained | 18122 | 18122 | 0.00% | Yes |
| photo-bmp-high-quality | compressed | 330726 | 35438 | 89.28% | Yes |
| audio-wav-zip | compressed | 365970 | 320977 | 12.29% | Yes |
| video-regression-source | compressed | 162897 | 57018 | 65.00% | Yes |
| video-regression-portrait | compressed | 162897 | 57018 | 65.00% | Yes |
| video-regression-tiny | compressed | 1731 | 1285 | 25.77% | Yes |
| video-flower-no-audio | compressed | 964919 | 723244 | 25.05% | Yes |

## Inputs and Provenance

- [MDN photograph](https://mdn.github.io/shared-assets/images/examples/grapefruit-slice.jpg): one original 332 × 332 JPEG, 18,122 bytes. TIFF and opaque BMP inputs are local conversions of this same photograph. Their larger starting sizes explain their savings; these results do not mean the original JPEG became smaller. The original JPEG was retained at every tested setting.
- [MDN video](https://mdn.github.io/shared-assets/videos/flower.mp4): one original MP4 with AAC audio. The video-only case is a stream copy of its video with the audio track removed, without re-encoding the input video. The original audio-bearing case remains rejected.
- [MDN audio](https://mdn.github.io/shared-assets/audio/t-rex-roar.mp3): one MP3 recording. The WAV input is a PCM decode of this MP3, not a newly recorded lossless master. ALAC preserves that decoded WAV exactly; it cannot restore quality lost in the original MP3. The MP3 itself was retained when AAC did not produce a smaller result.
- macOS `/System/Library/Sounds/Hero.aiff`: copied unchanged for a separate real AIFF-to-ALAC case.
- [Khronos Damaged Helmet asset](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/DamagedHelmet): a self-contained GLB. The project-folder input splits its JSON and binary chunk into equivalent glTF and BIN files. Geometry and texture data are unchanged. Direct GLB optimization retained the compact original; the project ZIP saved 10.51%.
- Repository README, format guide, and Swift model source: snapshots copied before the run for a real document/source-code ZIP.
- The existing source/portrait/tiny MP4 fixtures: three synthetic regression controls, distinguished from downloaded media.

Downloaded and generated inputs are development artifacts in `.build/real-files/inputs`; they are not bundled in Pliegue. Source download details are in [the local input record](../.build/real-files/SOURCES.md).

## Independent Checks

Python's independent ZIP64 parser checked CRCs, entry paths, and extracted SHA-256 hashes against every included source. FFmpeg independently decoded accepted images, compared RGBA hashes for lossless PNG, and checked JPEG dimensions. It compared decoded PCM32 hashes for ALAC, and decoded AAC while checking sample rate and channel layout. Accepted videos were fully decoded to compare frame counts and oriented dimensions; the two audio-bearing synthetic video cases also matched compressed audio hashes and decoded PCM hashes.

The development FFmpeg binary is used only to prepare clearly labeled inputs and independently verify outputs. It is not a runtime dependency, linked library, fallback encoder, or bundled executable in Pliegue.

Machine-readable evidence and accepted outputs:

- [Native results](../.build/real-files/final/results.json)
- [Independent checks](../.build/real-files/final/independent-checks.json)
- [Accepted output directory](../.build/real-files/final/)
- [Validation manifest](../.build/real-files/manifest.json)

## Issue Found and Protection Added

The MDN MP4 exposed zero-sample audio control markers that were incorrectly treated as missing audio payload. The code now excludes marker-only buffers from payload hashing and media-frame counting while still rejecting nonempty buffers with missing payload. Regression tests cover both cases.

A stricter follow-up revealed an AAC trim/edit timing issue: the initial encoded result retained compressed audio data but changed the audio track's presentation duration from 5.011 to approximately 4.968 seconds. Video verification now checks each audio track's start time and duration within 5 ms, in addition to payload hashes and video frames. That file is discarded and ZIP is offered as the safe alternative. Correct handling of this AAC edit-list case is still required before claiming broad video compatibility.

The tiny-video test was also corrected to accept genuinely smaller output from newer encoder versions rather than assuming its fixture must always grow.

## Execution Context and Remaining Limits

The restricted command-line process cannot obtain HEVC/AAC/ALAC encoders. A separate native diagnostic app, with the same sandbox entitlements as Pliegue and public fixtures inside its bundle, successfully exercised them. This distinguishes terminal restrictions from actual app-engine behavior.

The latest XCTest run executed 33 tests: 27 passed, six codec integration tests skipped due to the command-line restriction, zero failures. Those skips remain skips; native diagnostic results are reported separately.

The diagnostic host bypasses file selection with bundled test assets. It verifies the same compression and saving services, not the production file-importer/open-save GUI path. The chooser's disabled Open button during automation remains unresolved and requires manual validation. These results are not an App Store release certification or a completed end-to-end UI test.

## Reproduce

With the local fixtures and manifest still present:

```sh
swiftc -parse-as-library -module-cache-path .build/validation-module-cache \
  Sources/PliegueCore/*.swift scripts/ValidateFiles.swift -lz \
  -o .build/real-files/PliegueValidate
.build/real-files/PliegueValidate .build/real-files/manifest.json .build/real-files/outputs
```

The CLI exits with status 1 when any case fails, after writing every result. Native codec errors in a restricted process are expected and are not successes. For the app-hosted run, close any previous diagnostic host, then build and open:

```sh
./scripts/build-validation-app.sh .build/real-files
open .build/real-files/PliegueValidation.app
```

In this restricted compiler environment, add `-disable-sandbox` to the build-script invocation so Apple's SwiftUI macro plugin can run. This is a compiler option; the resulting diagnostic app keeps its sandbox entitlements. Its window displays the actual report path in its own temporary directory. Copy only accepted result paths listed in the JSON when collecting artifacts; older output directories may contain files from earlier rejected runs.

Run independent checks against the collected `final` directory:

```sh
python3 scripts/verify-validation.py .build/real-files final
```
