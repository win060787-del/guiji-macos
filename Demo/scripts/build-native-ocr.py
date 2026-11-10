#!/usr/bin/env python3
"""Rebuild the pinned arm64 OCR dependency with Xcode tools and CMake; no runtime downloads."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, urllib.request
root = pathlib.Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'Packaging/NativeOCR/manifest.json').read_text())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cmake', default='cmake')
parser.add_argument('--cache', type=pathlib.Path, default=pathlib.Path.home() / 'Library/Caches/NovaContextChecks/native-ocr')
a = parser.parse_args(); cache = a.cache.resolve(); cache.mkdir(parents=True, exist_ok=True)
prefix = cache / 'prefix'; src = cache / 'src'; src.mkdir(exist_ok=True)
def run(*args): subprocess.run([str(v) for v in args], check=True)
def fetch(url, dest, sha):
    if not dest.exists(): dest.write_bytes(urllib.request.urlopen(url).read())
    if hashlib.sha256(dest.read_bytes()).hexdigest() != sha: raise RuntimeError(f'Checksum mismatch: {dest.name}')
for name, item in manifest['sources'].items():
    archive = cache / (name + '.tar.gz'); fetch(item['url'], archive, item['sha256'])
    source = src / (name + '-' + manifest[name])
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                target = (src / member.name).resolve()
                if not target.is_relative_to(src.resolve()) or not (member.isfile() or member.isdir()):
                    raise RuntimeError('Unsafe archive member')
            tar.extractall(src)
common = ['-DCMAKE_BUILD_TYPE=Release', f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DBUILD_SHARED_LIBS=OFF']
for name, directory, flags in [
    ('lept', 'leptonica-' + manifest['leptonica'], ['-DBUILD_PROG=OFF'] + [f'-DENABLE_{v}=OFF' for v in ['ZLIB','PNG','JPEG','GIF','TIFF','WEBP','OPENJPEG']]),
    ('tess', 'tesseract-' + manifest['tesseract'], [f'-DCMAKE_PREFIX_PATH={prefix}', '-DBUILD_TRAINING_TOOLS=OFF','-DBUILD_TESTS=OFF','-DOPENMP_BUILD=OFF','-DDISABLE_TIFF=ON','-DDISABLE_ARCHIVE=ON','-DDISABLE_CURL=ON','-DGRAPHICS_DISABLED=ON','-DENABLE_NATIVE=OFF','-DCMAKE_CXX_FLAGS=-DTESSERACT_DISABLE_DEBUG_FONTS'])]:
    build = cache / (name + '-build')
    run(a.cmake, '-S', src / directory, '-B', build, *common, *flags)
    run(a.cmake, '--build', build, '--parallel', '4'); run(a.cmake, '--install', build)
headers = cache / 'headers'; headers.mkdir(exist_ok=True)
shutil.copy(root / 'Packaging/NativeOCR/NativeOCR.h', headers)
(headers / 'module.modulemap').write_text('module NativeOCR {\n header "NativeOCR.h"\n export *\n}\n')
run('xcrun','clang','-arch','arm64','-mmacosx-version-min=14.0',f'-I{prefix}/include','-c',root/'Packaging/NativeOCR/NativeOCR.c','-o',cache/'NativeOCR.o')
run('/usr/bin/libtool','-static','-o',cache/'libNativeOCR.a',cache/'NativeOCR.o',prefix/'lib/libtesseract.a',prefix/'lib/libleptonica.a')
output = root / 'Vendor/NativeOCR.xcframework'
def removal_error(function, path, error):
    if not isinstance(error[1], FileNotFoundError): raise error[1]
if output.exists(): shutil.rmtree(output, onerror=removal_error)
run('xcodebuild','-create-xcframework','-library',cache/'libNativeOCR.a','-headers',headers,'-output',output)
models = root / 'Sources/ContextCore/Resources/tessdata'; models.mkdir(exist_ok=True)
for name, item in manifest['models'].items(): fetch(item['url'], models / (name+'.traineddata'), item['sha256'])
print('Built native OCR; sources and six bundled models verified.')
