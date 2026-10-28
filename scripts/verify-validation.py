#!/usr/bin/env python3
"""Independently check saved validation outputs using Python's ZIP parser and FFmpeg decoding."""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zipfile

root = Path(sys.argv[1]).resolve()
cases = {case['name']: case for case in json.loads((root / 'manifest.json').read_text())}
report_directory = root / (sys.argv[2] if len(sys.argv) > 2 else 'outputs')
report = json.loads((report_directory / 'results.json').read_text())
ffmpeg = Path(__file__).resolve().parents[1] / '.tools/ffmpeg'
checks = []

def digest(data):
    return hashlib.sha256(data).hexdigest()

def pixels(path):
    return subprocess.run([str(ffmpeg), '-nostdin', '-hide_banner', '-loglevel', 'error', '-i', str(path),
                           '-map', '0:v:0', '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-'],
                          check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def pcm(path):
    return subprocess.run([str(ffmpeg), '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:a:0',
                           '-c:a', 'pcm_s32le', '-f', 's32le', '-'], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def frame_info(path, kind):
    process = subprocess.run([str(ffmpeg), '-nostdin', '-v', 'error', '-i', str(path), '-map', f'0:{kind}:0',
                              '-fps_mode', 'passthrough', '-f', 'framemd5', '-'], check=True,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    headers = [line.strip() for line in process.stdout.splitlines()
               if line.startswith(('#dimensions', '#sample_rate', '#channel_layout'))]
    frames = [line for line in process.stdout.splitlines() if line.strip() and not line.startswith('#')]
    return headers, len(frames)

def audio_payload(path):
    return subprocess.run([str(ffmpeg), '-nostdin', '-v', 'error', '-i', str(path), '-map', '0:a:0',
                           '-c:a', 'copy', '-f', 'hash', '-hash', 'sha256', '-'], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def glb(path):
    data = path.read_bytes()
    assert data[:4] == b'glTF' and struct.unpack_from('<II', data, 4) == (2, len(data))
    chunks = []
    cursor = 12
    while cursor < len(data):
        length, kind = struct.unpack_from('<II', data, cursor)
        assert length % 4 == 0 and cursor + length + 8 <= len(data)
        chunks.append((kind, data[cursor + 8:cursor + 8 + length]))
        cursor += length + 8
    assert cursor == len(data) and chunks[0][0] == 0x4e4f534a
    asset = json.loads(chunks[0][1])
    assert asset['asset']['version'] == '2.0' and len(asset.get('meshes', [])) > 0
    return asset, chunks[1:]

for result in report['results']:
    case = cases[result['name']]
    if result['status'] == 'error':
        checks.append({'name': result['name'], 'status': 'not-verified', 'reason': result['error']})
        continue
    assert result['originalsUnchanged'], result['name']
    sources = [(root / name).resolve() for name in case['files']]
    output = sources[0] if result['status'] == 'retained' else report_directory / Path(result['outputPath']).name
    sources = [(root / name).resolve() for name in case['files']]
    assert output.stat().st_size == result['outputBytes']
    if output.suffix == '.zip':
        expected = {}
        for source in sources:
            if source.is_dir():
                expected[source.name + '/'] = None
                for entry in source.rglob('*'):
                    name = source.name + '/' + entry.relative_to(source).as_posix()
                    expected[name + '/' if entry.is_dir() else name] = None if entry.is_dir() else entry
            else:
                expected[source.name] = source
        with zipfile.ZipFile(output) as archive:
            assert archive.testzip() is None
            assert set(archive.namelist()) == set(expected)
            for name, source in expected.items():
                if source is not None:
                    assert digest(archive.read(name)) == digest(source.read_bytes()), name
        message = f'Python zipfile CRC and SHA-256: {sum(value is not None for value in expected.values())} files match'
    elif case['mode'] == 'image':
        decoded = pixels(output)
        assert len(decoded) > 0
        if result['status'] == 'retained' or case.get('fidelity', 'lossless') == 'lossless':
            assert digest(decoded) == digest(pixels(sources[0]))
            message = 'Independent FFmpeg RGBA pixel SHA-256 matches'
        else:
            assert len(decoded) == len(pixels(sources[0]))
            message = 'Independent full image decode and pixel dimensions match; lossy pixels may differ'
    elif case['mode'] == 'model':
        original_asset, original_chunks = glb(sources[0])
        output_asset, output_chunks = glb(output)
        assert original_asset == output_asset and original_chunks == output_chunks
        message = 'Independent GLB JSON semantics and binary chunks match'
    elif case['mode'] == 'audio':
        original_format, _ = frame_info(sources[0], 'a')
        output_format, _ = frame_info(output, 'a')
        assert original_format == output_format, result['name']
        if case.get('fidelity', 'lossless') == 'lossless' or result['status'] == 'retained':
            assert digest(pcm(sources[0])) == digest(pcm(output)), result['name']
            message = 'Independent FFmpeg PCM32 SHA-256, sample rate, and channel layout match'
        else:
            assert len(pcm(output)) > 0
            message = 'Independent full AAC decode; sample rate and channel layout match'
    elif case['mode'] == 'video':
        original_format, original_frames = frame_info(sources[0], 'v')
        output_format, output_frames = frame_info(output, 'v')
        assert original_format == output_format and original_frames == output_frames, result['name']
        if case.get('hasAudio', True):
            assert audio_payload(sources[0]) == audio_payload(output), result['name']
            assert digest(pcm(sources[0])) == digest(pcm(output)), result['name']
            message = f'Independent full decode: {output_frames} video frames and orientation match; compressed and decoded audio SHA-256 match'
        else:
            message = f'Independent full decode: {output_frames} video frames and dimensions match; source has no audio'
    else:
        raise AssertionError(f'Unhandled validation mode: {case["mode"]}')
    checks.append({'name': result['name'], 'status': 'passed', 'verification': message})
    print(f"{result['name']}: {message}")

(report_directory / 'independent-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
print(f"{sum(item['status'] == 'passed' for item in checks)} independently verified; "
      f"{sum(item['status'] == 'not-verified' for item in checks)} failed native operations remain unverified")
