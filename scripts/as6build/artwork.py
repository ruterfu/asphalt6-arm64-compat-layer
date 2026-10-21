"""Package the HD background pack (dist/NativeArtwork.zip) from artwork/.

Every file is checked against the pins compiled into the layer
(host/src/HDArtworkPins.hpp) before it is packed.
"""
import hashlib
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PINS = ROOT / 'host/src/HDArtworkPins.hpp'
SOURCE = ROOT / 'artwork'


def pins():
    return dict(re.findall(r'\{"([^"]+)", "([0-9a-f]{64})"\}', PINS.read_text()))


def collect(source):
    """name -> bytes for every pinned file found in a folder or zip."""
    expected, found = pins(), {}
    if source.is_dir():
        for path in source.rglob('*'):
            if path.is_file() and path.name in expected:
                found[path.name] = path.read_bytes()
    else:
        with zipfile.ZipFile(source) as archive:
            for info in archive.infolist():
                name = Path(info.filename).name
                if name in expected and not info.is_dir():
                    found[name] = archive.read(info)
    return {n: b for n, b in found.items() if hashlib.sha256(b).hexdigest() == expected[n]}, expected


def package(target, source=SOURCE, log=print):
    verified, expected = collect(Path(source))
    missing = sorted(set(expected) - set(verified))
    if missing:
        raise SystemExit('HD artwork incomplete or altered: ' + ', '.join(missing[:5]))
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(verified):
            info = zipfile.ZipInfo('NativeArtwork/' + name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, verified[name])
    log('artwork: %s (%d files)' % (target, len(verified)))
    return target
