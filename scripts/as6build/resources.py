"""Assemble Asphalt6Data (the Documents resource folder) from the game copy.

Files are copied unchanged except for two compatibility transforms:
* menu movies: in-app purchase / promotion entry points become empty clips;
* three GLSL shaders: varyings repacked and a stray token removed so they
  compile on current OpenGL ES drivers.
The result must reproduce data/resource-manifest.json exactly.
"""
import hashlib
import json
import shutil
from pathlib import Path

from . import store_removal

DATA = Path(__file__).resolve().parent / 'data'
MANIFEST_NAME = 'resource-manifest.json'
MANIFEST_SHA256 = 'd265c2c49282cd6039db7d6459c167b7746d5bec6b4c44a41ae21e646e33ebea'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')) + '\n').encode()


def _shader_header(data, sign):
    # Shader resources store their first four bytes offset by position.
    return bytes((v + sign * (i + 1)) & 255 for i, v in enumerate(data[:4])) + data[4:]


def _replace_once(data, old, new):
    if data.count(old) != 1:
        raise RuntimeError('shader text not found exactly once: %r' % old)
    return data.replace(old, new)


_SHARED_VARYINGS = [
    (b'varying mediump     vec3 vNormal;', b'varying mediump     vec4 vNormal;'),
    (b'varying mediump\t\t\tvec3 vPosition;', b'varying mediump\t\t\tvec4 vPosition;'),
    (b'varying\tmediump   vec2 vCoord0;\r\n', b''),
]
# Current drivers reject the original vec2 varying beside the others; the
# coordinate travels in the spare w components of the normal and position.
_SHADER_EDITS = {
    'data/file000330.dat': _SHARED_VARYINGS + [
        (b'vNormal = Normal.xyz;', b'vNormal.xyz = Normal.xyz;'),
        (b'vPosition = Vertex.xyz;', b'vPosition.xyz = Vertex.xyz;'),
        (b'vCoord0 = TexCoord0;',
         b'mediump vec2 vCoord0 = TexCoord0;\r\n\tvNormal.w = vCoord0.x;\r\n\tvPosition.w = vCoord0.y;'),
    ],
    'data/file000634.dat': _SHARED_VARYINGS + [
        (b'(matworldi * eyePos).xyz - vPosition)', b'(matworldi * eyePos).xyz - vPosition.xyz)'),
        (b'normalize(vNormal);', b'normalize(vNormal.xyz);'),
        (b'mediump vec4 baseColor = vColor;',
         b'mediump vec4 baseColor = vColor;\r\n\t\tmediump vec2 vCoord0 = vec2(vNormal.w, vPosition.w);'),
    ],
}


def _fix_shader(name, data):
    if name == 'data/file000584.dat':
        # One stray ']' after a preprocessor directive.
        return _replace_once(data, b'#endif]', b'#endif')
    text = _shader_header(data, -1)
    for old, new in _SHADER_EDITS[name]:
        text = _replace_once(text, old, new)
    return _shader_header(text, +1)


def transform(name, data):
    if name in _SHADER_EDITS or name == 'data/file000584.dat':
        return _fix_shader(name, data)
    if name.startswith('data/') and data[:3] == b'GYV':
        result = store_removal.patch_file(data)
        if result is not None:
            patched, details = result
            store_removal.validate(patched, details)
            return patched
    return data


def build(app, output, log=print):
    """Copy and transform every expected resource from the .app into output."""
    expected = json.loads((DATA / MANIFEST_NAME).read_text())
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    produced, mismatched = {}, []
    for name, entry in sorted(expected['files'].items()):
        source = app / name
        if not source.is_file():
            raise RuntimeError('game copy is missing ' + name)
        data = transform(name, source.read_bytes())
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        produced[name] = {'bytes': len(data), 'sha256': sha(data)}
        if produced[name] != entry:
            mismatched.append(name)
    if mismatched:
        raise RuntimeError('resources differ from the supported game version: ' + ', '.join(mismatched[:5]))
    manifest = canonical({'files': produced, 'format': expected['format'], 'schema_version': 1,
                          'total_bytes': sum(e['bytes'] for e in produced.values()),
                          'total_files': len(produced)})
    if sha(manifest) != MANIFEST_SHA256:
        raise RuntimeError('resource manifest differs from the compiled pin')
    (output / MANIFEST_NAME).write_bytes(manifest)
    log('resources: %d files, %d bytes' % (len(produced), sum(e['bytes'] for e in produced.values())))
    return output / MANIFEST_NAME
