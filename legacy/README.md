# Archived Browser Prototype

The previous Python/FFmpeg implementation is retained for reference. It is not used, launched, or bundled by the native Swift app.

To run separately with Python 3.10 or later:

```sh
cd legacy
python3 server.py
```

ZIP uses Python's standard library. Video requires FFmpeg with libx265; set `FFMPEG_BINARY` to its absolute path if necessary. The repository's ignored `.tools/ffmpeg` is not a native app dependency.

```sh
cd legacy
python3 -m unittest discover -s tests -v
```

Historical interface and error strings remain in Spanish. New native code, identifiers, comments, and all project documentation are in English. See the root README for the current app.
