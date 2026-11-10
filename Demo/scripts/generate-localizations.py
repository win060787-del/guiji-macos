#!/usr/bin/env python3
"""Build the runtime catalog from reviewed translations; fail on omissions or placeholders."""
from pathlib import Path
import json, subprocess, tempfile
root=Path(__file__).resolve().parents[1]
keys=json.loads((root/'design/localization/keys.json').read_text())
# Swift multiline literals strip the opening newline, closing indent and final newline.
keys=[k[1:].removesuffix('\n      ').replace('\n      ','\n').removeprefix('      ') if k.startswith('\n      # AI') else k for k in keys]
values={lang:{} for lang in ['zh-Hans','zh-Hant','en','es','tr','ja']}
rows={}
for line in (root/'design/localization/translations.tsv').read_text().splitlines():
    row=line.split('\t'); assert len(row)==5,repr(line)
    index=int(row[0]); assert index not in rows,index
    rows[index]=[v.replace('\\n','\n') for v in row[1:]]
assert set(rows)==set(range(len(keys))),f'Missing: {set(range(len(keys)))-set(rows)}'
# Apple's ICU conversion is local and reproducible. Terminology is overridden for Taiwan usage.
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/'hant.swift'
    path.write_text('''import Foundation
let keys = try JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())
let result = keys.map { text in text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text }
FileHandle.standardOutput.write(try JSONEncoder().encode(result))
''')
    result=subprocess.run(['swift',str(path)],input=json.dumps(keys).encode(),capture_output=True,check=True)
    hant=json.loads(result.stdout)
for index,key in enumerate(keys):
    values['zh-Hans'][key]=key
    traditional=hant[index]
    for a,b in [('文件夾','資料夾'),('文件','檔案'),('項目','專案'),('服務器','伺服器'),('鑰匙串','鑰匙圈'),('代碼','程式碼'),('設置','設定'),('配置','設定'),('令牌','權杖')]: traditional=traditional.replace(a,b)
    values['zh-Hant'][key]=traditional
    for lang,value in zip(['en','es','tr','ja'],rows[index]):
        assert value and key.count('%@')==value.count('%@'),(index,lang,'empty or wrong placeholders')
        values[lang][key]=value
extras=json.loads((root/'design/localization/additions.json').read_text())
for key, translations in extras.items():
    assert set(translations)==set(values),(key,'incomplete languages')
    for lang,translation in translations.items():
        assert key.count('%@')==translation.count('%@'),(key,lang)
        values[lang][key]=translation
out=root/'Sources/ContextCore/Resources/Localizations.json'
out.write_text(json.dumps(values,ensure_ascii=False,indent=2)+'\n')
print(f'{len(values)} languages, {len(values["en"])} entries each')

# Bundle documentation for every locale, keeping document identifiers stable.
manuals=json.loads((root/'design/localization/manuals.json').read_text())
legal=json.loads((root/'design/localization/legal.json').read_text())
docs=root/'Sources/NovaContext/Resources/Documentation'
for lang in ['en','es','tr','ja']:
    directory=docs/lang; directory.mkdir(exist_ok=True)
    for filename,content in [('使用手册',manuals[lang]),('隐私政策',legal[lang]['privacy']),('使用条款',legal[lang]['terms'])]:
        (directory/(filename+'.md')).write_text(content+'\n')
# Traditional Chinese manuals use the same local ICU conversion as the UI.
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/'hant.swift'
    path.write_text('''import Foundation
let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!
FileHandle.standardOutput.write((text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text).data(using: .utf8)!)
''')
    destination=docs/'zh-Hant';destination.mkdir(exist_ok=True)
    for source in docs.glob('*.md'):
        if source.name.startswith('._'):continue
        converted=subprocess.run(['swift',str(path)],input=source.read_bytes(),capture_output=True,check=True).stdout.decode()
        for a,b in [('文件夾','資料夾'),('文件','檔案'),('項目','專案'),('服務器','伺服器'),('鑰匙串','鑰匙圈'),('代碼','程式碼'),('設置','設定'),('配置','設定')]:converted=converted.replace(a,b)
        (destination/source.name).write_text(converted)

# App Store drafts are independent from the submitted build and are not uploaded by this script.
store=json.loads((root/'design/localization/store.json').read_text())
metadata=root/'store-assets/metadata'
for lang,fields in store.items():
    directory=metadata/lang;directory.mkdir(exist_ok=True)
    for field,value in fields.items():(directory/(field+'.txt')).write_text(value+'\n')
with tempfile.TemporaryDirectory() as directory:
    path=Path(directory)/'hant.swift'
    path.write_text('import Foundation\nlet t = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!\nFileHandle.standardOutput.write((t.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? t).data(using: .utf8)!)')
    destination=metadata/'zh-Hant';destination.mkdir(exist_ok=True)
    for source in (metadata/'zh-Hans').glob('*.txt'):
        if source.name.startswith('._'):continue
        text=subprocess.run(['swift',str(path)],input=source.read_bytes(),capture_output=True,check=True).stdout.decode()
        for a,b in [('文件夾','資料夾'),('文件','檔案'),('項目','專案'),('服務器','伺服器'),('鑰匙串','鑰匙圈'),('代碼','程式碼'),('設置','設定'),('配置','設定')]:text=text.replace(a,b)
        (destination/source.name).write_text(text)

for field,value in store.get('zh-Hant',{}).items():
    (metadata/'zh-Hant'/(field+'.txt')).write_text(value+'\n')
