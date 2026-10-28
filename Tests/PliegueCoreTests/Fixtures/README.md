# Synthetic Media Fixtures

These short generated patterns and sine waves contain no user files or third-party recordings.

- `source.mp4`: two seconds of high-quality 320×180 H.264 at 24 fps with AAC audio.
- `tiny.mp4`: a quarter-second black 64×64 H.264 clip without audio, for small-file overhead and no-larger-output behavior. Whether it shrinks depends on the native encoder version.
- `portrait.mp4`: the source clip with a 90-degree display transform.

They were generated with a development copy of FFmpeg. Neither running native tests nor using the app requires FFmpeg.
