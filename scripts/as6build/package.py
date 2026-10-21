"""Link the compatibility layer and package an installable IPA."""
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

from . import resources

FRAMEWORKS = ('UIKit', 'Foundation', 'CoreGraphics', 'ImageIO', 'QuartzCore', 'AVFoundation',
              'CoreMedia', 'MediaPlayer', 'Metal', 'IOKit', 'SystemConfiguration', 'CoreMotion', 'OpenGLES')
# Icons and localized strings come from the user's game copy.
BUNDLE_RESOURCES = ('Default.png', 'Default@2x.png', 'Icon.png', 'Icon@2x.png', 'Icon-Small.png',
                    'Icon-Small@2x.png', 'en.lproj', 'de.lproj', 'es.lproj', 'fr.lproj', 'it.lproj',
                    'ja.lproj', 'ko.lproj', 'pt.lproj', 'zh.lproj', 'zh_Hans.lproj', 'zh_Hant.lproj')
EXECUTABLE = 'AS6NativeGame'
BUNDLE_ID = 'com.ruterfu.asphalt6compat'
ROOT = Path(__file__).resolve().parents[2]


def run(command):
    subprocess.run([str(part) for part in command], check=True)


def output(command):
    return subprocess.run([str(part) for part in command], check=True, text=True, capture_output=True).stdout.strip()


def info_plist(game_app, bundle_id):
    original = plistlib.loads((game_app / 'Info.plist').read_bytes())
    return {
        'CFBundleDevelopmentRegion': 'English',
        'CFBundleDisplayName': original.get('CFBundleDisplayName', 'Game'),
        'CFBundleExecutable': EXECUTABLE,
        'CFBundleIdentifier': bundle_id,
        'CFBundleIconFiles': original.get('CFBundleIconFiles', []),
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'Asphalt6ARM64',
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'CFBundleVersion': '1',
        'DTPlatformName': 'iphoneos',
        'LSRequiresIPhoneOS': True,
        'LSSupportsOpeningDocumentsInPlace': True,
        'MinimumOSVersion': '17.0',
        'NSAppleMusicUsageDescription': '用于游戏内的系统音乐库播放选项。你可以拒绝，继续使用游戏内置音乐。',
        'NSMotionUsageDescription': '通过重力感应控制赛车转向。',
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
        'UIDeviceFamily': [1, 2],
        'UIFileSharingEnabled': True,
        'UILaunchStoryboardName': '',
        'UIRequiredDeviceCapabilities': ['arm64'],
        'UIRequiresFullScreen': True,
        'UIStatusBarHidden': True,
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationLandscapeLeft',
                                             'UIInterfaceOrientationLandscapeRight'],
        'UIViewControllerBasedStatusBarAppearance': True,
        'AS6ResourceManifestSHA256': resources.MANIFEST_SHA256,
        'AS6ResourceLayout': 'documents-asphalt6data-v1',
    }


def link(build, executable):
    sdk = output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'])
    command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-target', 'arm64-apple-ios17.0', '-isysroot', sdk,
               # Host bridges register through static initializers; keep every member.
               '-Wl,-force_load,%s' % (build / 'libas6_ios_host.a'),
               '-Wl,-force_load,%s' % (build / 'libas6_aot_program.a'),
               build / 'libas6_aot_math.a', '-lz', '-lc++', '-lobjc', '-o', executable]
    for framework in FRAMEWORKS:
        command += ['-framework', framework]
    run(command)


def strip_signature(app):
    # The arm64 linker adds an ad-hoc signature; SideStore and similar tools
    # sign the app on install, so ship it unsigned.
    run(['codesign', '--remove-signature', app / EXECUTABLE])
    shutil.rmtree(app / '_CodeSignature', ignore_errors=True)


def package(build, game_app, manifest, dist, log=print):
    staging = build / 'Payload'
    if staging.exists():
        shutil.rmtree(staging)
    app = staging / 'Asphalt6ARM64.app'
    app.mkdir(parents=True)
    link(build, app / EXECUTABLE)
    (app / 'Info.plist').write_bytes(plistlib.dumps(info_plist(game_app, BUNDLE_ID)))
    (app / 'PkgInfo').write_bytes(b'APPL????')
    (app / 'ResourcePack').mkdir()
    shutil.copyfile(manifest, app / 'ResourcePack' / resources.MANIFEST_NAME)
    for name in BUNDLE_RESOURCES:
        source = game_app / name
        if source.is_dir():
            shutil.copytree(source, app / name)
        elif source.is_file():
            shutil.copyfile(source, app / name)
    (app / 'Licenses').mkdir()
    shutil.copyfile(ROOT / 'aot/math/NOTICE.md', app / 'Licenses/softfloat-NOTICE.md')
    strip_signature(app)

    dist.mkdir(parents=True, exist_ok=True)
    ipa = dist / 'Asphalt6ARM64.ipa'
    with zipfile.ZipFile(ipa, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(staging.rglob('*')):
            if path.is_file() or path.is_symlink():
                archive.write(path, path.relative_to(build))
    log('package: %s (unsigned, bundle id %s)' % (ipa, BUNDLE_ID))
    return ipa
