#!/usr/bin/env python3
"""Generate a local, normalized archive for Organizer from external-drive output."""
import importlib.util, shutil, sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('packager',root/'scripts/package-app-store.py')
packager=importlib.util.module_from_spec(spec); spec.loader.exec_module(packager)
build = sys.argv[1] if len(sys.argv) > 1 else '25'
if not build.isdecimal(): raise SystemExit('Build number must be numeric.')
source=root/f'dist/Guiji-1.0.0-{build}-distribution.xcarchive'
target=Path.home()/f'Library/Caches/NovaContextRelease/Guiji-1.0.0-{build}-upload.xcarchive'
if target.exists(): raise SystemExit('Staged archive already exists; preserve it.')
shutil.copytree(source,target,ignore=shutil.ignore_patterns('._*'))
for item in target.rglob('*'):
    item.chmod(0o755 if item.is_dir() else 0o644)
source_app=next(p for p in (source/'Products/Applications').glob('*.app') if p.is_dir() and not p.name.startswith('._'))
app=target/'Products/Applications'/source_app.name
shutil.rmtree(app)
packager.prepare_app(source_app,app)
print(target)
