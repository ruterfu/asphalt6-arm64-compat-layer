#!/usr/bin/env python3
"""Build the Asphalt 6 arm64 compatibility layer from your own game copy.

    python3 scripts/buildGame.py Asphalt6.ipa

Stages (each verified against pinned hashes before the next one runs):
  1. extract   unpack the IPA and check it is the supported 1.3.2 release
  2. resources assemble Asphalt6Data for the app's Documents folder
  3. codegen   translate the game program into C++ sources under generated/
  4. compile   build the iOS libraries with CMake
  5. package   link, sign (ad-hoc unless --identity/--profile) and write the IPA

Outputs land in dist/: Asphalt6Compat.ipa and Asphalt6Data.zip.
"""
import argparse
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from as6build import codegen, package, resources  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SUPPORTED_VERSION = '1.3.2'
ARMV7_SHA256 = '4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00'


def log(message):
    print('[buildGame] ' + message, flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def extract(ipa, work):
    target = work / 'ipa'
    if target.exists():
        shutil.rmtree(target)
    with zipfile.ZipFile(ipa) as archive:
        for member in archive.infolist():
            path = Path(member.filename)
            if path.is_absolute() or '..' in path.parts:
                raise SystemExit('unsafe path in IPA: ' + member.filename)
        archive.extractall(target)
    apps = sorted((target / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('expected exactly one .app inside Payload/')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleVersion') != SUPPORTED_VERSION:
        raise SystemExit('unsupported game version %s (need %s)' % (info.get('CFBundleVersion'), SUPPORTED_VERSION))
    program = app / info['CFBundleExecutable']
    armv7 = work / 'program.armv7'
    subprocess.run(['lipo', '-thin', 'armv7', str(program), '-output', str(armv7)], check=True)
    if sha256(armv7) != ARMV7_SHA256:
        raise SystemExit('game program differs from the supported release; aborting')
    log('extract: %s %s verified' % (info.get('CFBundleDisplayName', app.name), SUPPORTED_VERSION))
    return app, armv7


def compile_ios(generated, build, jobs):
    configure = ['cmake', '-S', str(ROOT), '-B', str(build), '-G', 'Unix Makefiles',
                 '-DCMAKE_BUILD_TYPE=', '-DCMAKE_C_FLAGS=-g', '-DCMAKE_CXX_FLAGS=-g', '-DCMAKE_OBJCXX_FLAGS=-g',
                 '-DCMAKE_CXX_EXTENSIONS=OFF', '-DCMAKE_OBJCXX_EXTENSIONS=OFF',
                 '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                 '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0', '-DAS6_GENERATED_DIR=%s' % generated]
    subprocess.run(configure, check=True)
    log('compile: %d jobs (the translated program takes about an hour)' % jobs)
    subprocess.run(['cmake', '--build', str(build), '--target', 'as6_ios_host', '--', '-j%d' % jobs], check=True)


def zip_resources(folder, target):
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_STORED) as archive:
        for path in sorted(folder.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(folder.parent))
    log('resources: %s' % target)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('ipa', type=Path, help='your Asphalt 6 1.3.2 IPA')
    parser.add_argument('--work', type=Path, default=ROOT / 'build/work')
    parser.add_argument('--dist', type=Path, default=ROOT / 'dist')
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument('--bundle-id', default=package.DEFAULT_BUNDLE_ID)
    parser.add_argument('--identity', help='codesign identity, e.g. "Apple Development: ..."')
    parser.add_argument('--profile', type=Path, help='provisioning profile matching --identity')
    parser.add_argument('--ghidra', type=Path, help='Ghidra 12.1.4 install (downloaded if omitted)')
    parser.add_argument('--jdk', type=Path, help='JDK 21 home (downloaded if omitted)')
    parser.add_argument('--skip-compile', action='store_true', help='stop after generating sources')
    args = parser.parse_args()
    if bool(args.identity) != bool(args.profile):
        parser.error('--identity and --profile go together')

    args.work.mkdir(parents=True, exist_ok=True)
    app, armv7 = extract(args.ipa.resolve(), args.work)
    data = resources.build(app, args.work / 'Asphalt6Data', log)
    generated = ROOT / 'generated'
    codegen.generate(armv7, app, generated, args.work, ghidra=args.ghidra, jdk=args.jdk, log=log)
    if args.skip_compile:
        return
    build = ROOT / 'build/ios'
    compile_ios(generated, build, args.jobs)
    package.package(build, app, data, args.dist, args.bundle_id, args.identity, args.profile, log)
    zip_resources(args.work / 'Asphalt6Data', args.dist / 'Asphalt6Data.zip')
    log('done: install dist/Asphalt6Compat.ipa, then copy Asphalt6Data into the app\'s Documents folder')


if __name__ == '__main__':
    main()
