#!/usr/bin/env python3
import hashlib, json, plistlib, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
archive=Path(sys.argv[1]) if len(sys.argv)>1 else ROOT/'dist/Guiji-1.0.0-25-distribution.xcarchive'
app=next(p for p in (archive/'Products/Applications').glob('*.app') if p.is_dir() and not p.name.startswith('._'))
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='com.novatechai.context'
assert set(info['CFBundleLocalizations'])=={'zh-Hans','zh-Hant','en','es','tr','ja'}
assert info['CFBundleShortVersionString']=='1.0.0' and info['CFBundleVersion']=='25'
assert info['NovaContextAppStoreBuild'] is True
assert info['CFBundleName'] == info['CFBundleDisplayName'] == 'Guiji: Markdown & Keys'
for lang, name in [('zh-Hans', '归记-MD编辑文件密码管理器'), ('zh-Hant', '歸記')]:
 names = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'xml1', '-o', '-', str(app / f'Contents/Resources/{lang}.lproj/InfoPlist.strings')]))
 assert names['CFBundleName'] == names['CFBundleDisplayName'] == name
sample = app/'Contents/Resources/Resources/SampleProjectEnglish'
assert (sample/'README.md').read_text().startswith('# Orbit Project Workbench')
assert {f.suffix for f in (sample/'references').iterdir()} == {'.pdf', '.png', '.docx', '.xlsx', '.pptx'}
exe=app/'Contents/MacOS'/info['CFBundleExecutable']
architectures=subprocess.check_output(['lipo','-archs',str(exe)],text=True).strip()
assert architectures=='arm64',architectures
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
ent=plistlib.loads(subprocess.check_output(['codesign','-d','--entitlements',':-',str(app)],stderr=subprocess.DEVNULL))
expected=plistlib.loads((ROOT/'Packaging/AppStore.entitlements').read_bytes())
for key,value in expected.items():assert ent.get(key)==value,key
assert not ent.get('com.apple.security.get-task-allow')
assert 'com.apple.security.network.server' not in ent
assert ent.get('com.apple.security.network.client') is True
assert not any('temporary-exception' in key for key in ent)
privacy=plistlib.loads((app/'Contents/Resources/PrivacyInfo.xcprivacy').read_bytes())
assert privacy['NSPrivacyTracking'] is False
categories={x['NSPrivacyAccessedAPIType']:x['NSPrivacyAccessedAPITypeReasons'] for x in privacy['NSPrivacyAccessedAPITypes']}
assert categories['NSPrivacyAccessedAPICategoryUserDefaults']==['CA92.1']
for name in ['使用手册','隐私政策','使用条款']:
 file=app/f'Contents/Resources/Resources/Documentation/{name}.md'
 assert file.read_bytes()==(ROOT/f'Sources/NovaContext/Resources/Documentation/{name}.md').read_bytes()
zip_manifest=app/'Contents/Resources/ZIPFoundation_ZIPFoundation.bundle/Contents/Resources/PrivacyInfo.xcprivacy'
assert zip_manifest.is_file(),'Dependency privacy manifest missing'
for name in ['MiaoYan','ZIPFoundation','cmark']:
 assert (app/f'Contents/Resources/Licenses/{name}-LICENSE.txt').is_file()
ocr = json.loads((ROOT/'Packaging/NativeOCR/manifest.json').read_text())
core = app/'Contents/Resources/NovaContext_ContextCore.bundle/Contents/Resources/Resources'
for language, model in ocr['models'].items():
 assert hashlib.sha256((core/'tessdata'/f'{language}.traineddata').read_bytes()).hexdigest()==model['sha256']
for name in ['Tesseract','Leptonica','Tessdata']:
 assert (app/f'Contents/Resources/Licenses/{name}-LICENSE.txt').is_file()
links=subprocess.check_output(['otool','-L',str(exe)],text=True)
assert '/opt/' not in links and 'conda' not in links and 'libtesseract' not in links and 'liblept' not in links
assert (app/'Contents/Resources/nova-agent.py').is_file()
assert (app/'Contents/Resources/AppIcon.icns').is_file()
signature=subprocess.run(['codesign','-dv','--verbose=2',str(app)],capture_output=True,text=True,check=True).stderr
assert 'TeamIdentifier=7DXNZ5SH9Z' in signature
is_distribution = 'Authority=Apple Distribution:' in signature
assert is_distribution or 'Authority=Apple Development:' in signature
result={'archive_checks_passed':True,'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],'bundle_id':info['CFBundleIdentifier'],'architectures':architectures,'team':'7DXNZ5SH9Z','sandbox':True,'privacy_manifests':2,'signing_stage':('Apple Distribution archive' if is_distribution else 'Apple Development archive; not an App Store distribution export'),'testflight_profile_embedded':(app/'Contents/embedded.provisionprofile').exists(),'full_app_device_qa_completed':False,'uploaded':False,'submitted':False}
(ROOT/('design/validation/app-store-distribution.json' if is_distribution else 'design/validation/app-store-archive.json')).write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
