#!/usr/bin/env python3
"""Package an Xcode distribution archive with Apple's productbuild. Never uploads."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = '3rd Party Mac Developer Installer: NovaTech AI Limited (7DXNZ5SH9Z)'


def verify_app(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr
    if 'Authority=Apple Distribution: NovaTech AI Limited (7DXNZ5SH9Z)' not in signature:
        raise ValueError('Expected an Apple Distribution archive for the company team')
    ent = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.DEVNULL))
    if 'com.apple.security.network.server' in ent or ent.get('com.apple.security.network.client') is not True:
        raise ValueError('Incorrect network entitlement set')
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def prepare_app(source, destination):
    subprocess.run(['ditto', '--norsrc', '--noextattr', '--noacl', str(source), str(destination)], check=True)
    # AppleDouble metadata sidecars are not application resources.
    for sidecar in destination.rglob('._*'):
        if sidecar.is_file(): sidecar.unlink()
    # External drives can flatten permissions. Set installation modes on the local copy only.
    for item in destination.rglob('*'):
        if item.is_dir():
            item.chmod(0o755)
        elif item.is_file():
            item.chmod(0o644)
    destination.chmod(0o755)
    info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
    (destination / 'Contents/MacOS' / info['CFBundleExecutable']).chmod(0o755)
    subprocess.run(['codesign', '--force', '--deep', '--options', 'runtime', '--entitlements', str(ROOT / 'Packaging/AppStore.entitlements'), '--sign', 'Apple Distribution: NovaTech AI Limited (7DXNZ5SH9Z)', str(destination)], check=True)
    return verify_app(destination)


def file_hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def verify_payload(package, app, staging):
    subprocess.run(['pkgutil', '--check-signature', str(package)], check=True, stdout=subprocess.DEVNULL)
    expanded = staging / 'expanded'
    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True)
    apps = list(expanded.rglob(app.name))
    if len(apps) != 1 or file_hashes(apps[0]) != file_hashes(app):
        raise ValueError('Installer payload differs from the signed app')
    verify_app(apps[0])
    bom = next(expanded.rglob('Bom'))
    listing = subprocess.check_output(['lsbom', '-p', 'fMUG', str(bom)], text=True)
    expected = './' + app.name + '\tdrwxr-xr-x \troot\twheel'
    if expected not in listing:
        raise ValueError('Installer app directory has incorrect ownership or permissions')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, default=ROOT / 'dist/Guiji-1.0.0-25-distribution.xcarchive')
    args = parser.parse_args()
    source = next(p for p in (args.archive / 'Products/Applications').glob('*.app') if p.is_dir() and not p.name.startswith('._'))
    verify_app(source)
    cache = Path.home() / 'Library/Caches/NovaContextRelease'
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='package-', dir=cache) as directory:
        stage = Path(directory)
        app = stage / 'Guiji.app'
        info = prepare_app(source, app)
        version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
        package = stage / f'Guiji-{version}-{build}.pkg'
        subprocess.run(['productbuild', '--sign', INSTALLER, '--component', str(app), '/Applications', str(package)], check=True)
        verify_payload(package, app, stage)
        output = ROOT / f'dist/AppStoreExport-{version}-{build}'
        output.mkdir(parents=True, exist_ok=True)
        target = output / package.name
        shutil.copy2(package, target)
        result = {'version': version, 'build': build, 'bundle_id': info['CFBundleIdentifier'],
                  'package': str(target), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(),
                  'app_signature': 'Apple Distribution', 'installer_signature': INSTALLER,
                  'local_package_validation_passed': True,
                  'testflight_profile_embedded': (app / 'Contents/embedded.provisionprofile').exists(),
                  'apple_server_validated': False, 'uploaded': False, 'submitted': False}
        report = ROOT / 'design/validation/app-store-package.json'
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
