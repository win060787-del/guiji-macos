import hashlib,json,platform,re,statistics,sys,unicodedata
from pathlib import Path
root=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
fixtures=json.loads((root/'fixtures/manifest.json').read_text());answers={x['id']:x for x in fixtures}
def normalize(s):return re.sub(r'\s+','',unicodedata.normalize('NFKC',s))
def distance(a,b):
 row=list(range(len(b)+1))
 for i,x in enumerate(a,1):
  following=[i]
  for j,y in enumerate(b,1):following.append(min(following[-1]+1,row[j]+1,row[j-1]+(x!=y)))
  row=following
 return row[-1]
sets={};summaries=[]
for name in ['vision-production','vision-compat','vision-compat-serial','tesseract','rapidocr']:
 data=[json.loads(x) for x in (root/(name+'.jsonl')).read_text().splitlines() if x.startswith('{')]
 for row in data:
  source=answers[row['id']];expected=normalize(source['text']);actual=normalize(row.get('text',''))
  row['character_errors']=distance(expected,actual);row['reference_characters']=len(expected);row['cer']=row['character_errors']/len(expected)
  row['strict_text_match']=row.get('text','').strip()==source['text'].strip()
 successful=[x for x in data if x['ok']]
 values=[x.get('warm_median_seconds',x.get('seconds',0)) for x in successful]
 summary={'engine':name,'returned_results':len(successful),'fixtures':len(data),'micro_cer':sum(x['character_errors'] for x in data)/sum(x['reference_characters'] for x in data),'warm_or_single_api_median_seconds':statistics.median(values) if values else None,'peak_rss_bytes':max([x.get('peak_rss_bytes',0) for x in data]),'code_strict_match':next(x['strict_text_match'] for x in data if x['id']=='code')}
 sets[name]=data;summaries.append(summary)
 result=out/(name+'.json');result.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
assets={}
env=root/'env'
models=env/'lib/python3.12/site-packages/rapidocr/models'
for name,files in [('rapidocr_models',list(models.glob('*.onnx'))),('tesseract_selected_models',[env/'share/tessdata'/(lang+'.traineddata') for lang in ['eng','chi_sim','chi_tra','jpn','spa','tur']]),('tesseract_libraries',[env/'lib/libtesseract.dylib',env/'lib/liblept.dylib'])]:
 assets[name]=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in files if p.exists()]
report={'date':'2026-11-01','platform':platform.platform(),'architecture':platform.machine(),'samples':fixtures,'summaries':summaries,'assets':assets,'methodology':['Synthetic 1000x360 printed samples, seven clean plus three blurred; no user files','CER uses Unicode NFKC and ignores whitespace; case and remaining punctuation retained','Code exact match separately retains whitespace and punctuation','Tesseract 5.5.3: native C API via Python ctypes, psm6, known language + English hint, two-thread limit','RapidOCR 3.10.0 / ONNX Runtime 1.31.1: default PP-OCRv6 small det/rec, v4 classifier, CPU2/1 threads, no CoreML','Tesseract/RapidOCR warm timing is median of second and third call; model initialization separately recorded','Vision API initial preflight paths ran concurrently and are not valid speed comparisons; serial compatibility retest recorded separately','Peak RSS is test process high-water mark, not final native application memory or guaranteed package increase','Returned result is not an accuracy pass; CER and exact code output determine quality','No App Store, entitlement or application source changes made']}
(out/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summaries,ensure_ascii=False,indent=2))
for name in ['tesseract','rapidocr']:
 print(name,[(x['id'],round(x['cer']*100,2),round(x.get('warm_median_seconds',0)*1000)) for x in sets[name]])
print('model bytes', {k:sum(x['bytes'] for x in v) for k,v in assets.items()})

# Preserve synthetic fixtures and repeat results for independent inspection.
import shutil,subprocess
fixtureout=out/'fixtures';fixtureout.mkdir(exist_ok=True)
for item in fixtures:
    source=root/'fixtures'/item['file'];target=fixtureout/item['file'];shutil.copy2(source,target)
    item['sha256']=hashlib.sha256(source.read_bytes()).hexdigest()
(fixtureout/'manifest.json').write_text(json.dumps(fixtures,ensure_ascii=False,indent=2)+'\n')
repeat=[]
for engine in ['tesseract','rapidocr']:
    lines=[json.loads(x) for x in (root/(engine+'-repeat.jsonl')).read_text().splitlines() if x.startswith('{')]
    (out/(engine+'-repeat.json')).write_text(json.dumps(lines,ensure_ascii=False,indent=2)+'\n')
    assert len(lines)==len(fixtures) and all(x['ok'] for x in lines)
    assert [x['text'] for x in lines]==[x['text'] for x in sets[engine]],engine+' repeat text differs'
    repeat.append({'engine':engine,'returned_results':len(lines),'text_identical_to_first_run':True})
report['repeat_validation']=repeat
report['cpu']=subprocess.check_output(['/usr/sbin/sysctl','-n','machdep.cpu.brand_string'],text=True).strip()
report['physical_memory_bytes']=int(subprocess.check_output(['/usr/sbin/sysctl','-n','hw.memsize'],text=True))
report['methodology']+=['Vision compatibility revision2 reported only en/fr/it/de/es/pt/zh-Hans/zh-Hant support; Japanese and Turkish were not declared supported','Tesseract uses known language hints and single-block psm6; RapidOCR includes detection and uses a unified multilingual model, so speed is configuration-specific','Failed engine calls are scored as deleted reference characters in micro_cer; no-result rows do not establish recognition accuracy','Fixtures include normal printed pages and artificial Gaussian blur, not real camera captures, handwriting, tables or multicolumn scans']
report['decision']='Prototype native Tesseract as the lightweight independent fallback; preserve OCR preview/review because code whitespace changed. RapidOCR is the next candidate for code/layout fidelity. Do not depend on Vision revision2 alone due to failed serial retest.'
(out/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
by={x['engine']:x for x in summaries}
tess=by['tesseract'];rapid=by['rapidocr']
rows=[]
for name,key in [('Tesseract 5.5.3','tesseract'),('RapidOCR 3.10.0 + ONNX Runtime 1.31.1','rapidocr')]:
    s=by[key];rows.append(f"| {name} | {s['returned_results']}/10 | {s['micro_cer']:.2%} | {s['warm_or_single_api_median_seconds']*1000:.1f} ms | {s['peak_rss_bytes']/1048576:.1f} MiB | {'yes' if s['code_strict_match'] else 'no'} |")
text='''# 归记 OCR 独立对比测试 — 2026-11-01

本轮只测试，不修改应用源码、权限或 App Store 送审记录。测试使用虚构文字，不读取用户资料、真实 Token 或钥匙串。

## 环境与样例

Apple M6、16 GiB 内存、macOS 27.0、arm64。10 张 1000×360 合成图片：简中、繁中、英语、日语、西语、土耳其语及代码共 7 张清晰样例，另有中英日各一张轻度高斯模糊样例。字体、原文、文件哈希保存在 fixtures/manifest.json。

这组样例验证基础可用性，不代表真实拍照、手写、多栏、表格、复杂版式或所有文档的准确率。

## 开源引擎结果

| 引擎 | 返回结果 | 字符错误率 | 单张暖运行中位耗时 | 测试进程峰值 RSS | 代码逐字一致 |
|---|---:|---:|---:|---:|---|
'''+ '\n'.join(rows)+'''

两套开源引擎分别独立复跑一轮，共各 20/20 次返回结果，第二轮输出与第一轮完全一致。

**评分边界：**字符错误率使用 Unicode NFKC 归一化并忽略空白，但保留大小写和其余标点。不能解读为文件逐字无损。

代码样例中，Tesseract 把 `https://example.com` 输出为 `https://examp le. com`；RapidOCR 在此单一样例中保留了原文。不要直接把 OCR 结果作为可执行代码、配置或可信凭证使用。

Tesseract 使用已知语言+英语提示，PSM 6 单一文字块；RapidOCR 使用统一多语言模型并包含检测。每张调用 3 次，表中耗时取后两次的中位数，再对全部样例取中位数；模型初始化另记。配置与任务步骤不同，速度不能泛化为所有资料上的排名。

峰值 RSS 是测试进程高水位。Tesseract 通过 Python ctypes 调原生 C API；RapidOCR 经 Python、OpenCV 和 ONNX Runtime。它不是最终 Swift App 的内存或增加的包体。

## Apple 路径

- 当前生产 Vision 配置：0/10，复现 e5rt 计算操作创建失败（code 13）。
- Vision revision 2 + CPU：初始预检 10/10 返回结果，但字符错误率约 2.70%，代码不逐字一致；串行复测 0/10，再次出现 e5rt 错误。首次预检的两条 Apple 路径同时启动，因此不用于速度比较。
- revision 2 在本机声明的语言不含日语和土耳其语。不能因某些样例返回文字，就认为覆盖了全部六语言。
- 结论仅适用于当前本机和测试环境；不能据此断言 Vision 在所有 Mac 都不稳定，也不能把旧修订版视为已验证的完整修复。

## 模型与集成成本

- 本次 Tesseract 六语言模型合计约 '''+f"{sum(x['bytes'] for x in assets['tesseract_selected_models'])/1048576:.1f}"+''' MiB；libtesseract 与 liblept 两个主库合计约 '''+f"{sum(x['bytes'] for x in assets['tesseract_libraries'])/1048576:.1f}"+''' MiB，未包含其他动态库依赖。
- RapidOCR 三个模型合计约 '''+f"{sum(x['bytes'] for x in assets['rapidocr_models'])/1048576:.1f}"+''' MiB，另需推理运行库及图像处理依赖。
- 测试环境安装的 Conda/Python 全量依赖不是可直接上架的包。最终原生体积、签名、模型和依赖许可证、沙箱内执行仍需在接入时验证。本轮没有声称完成这些事项。

## 建议

先验证 Tesseract 的原生轻量兜底集成，保留结果预览与人工确认；当前 Vision 旧修订版本身不够可靠。若代码截图或复杂版式的还原成为重点，再优先验证 RapidOCR 的原生集成。两套开源引擎在本机均可独立于 Vision 工作。

PDF 有文字层时继续使用 PDFKit，只有扫描页面与图片进入 OCR。先不引入云端服务。

## 复现与来源

源码在 scripts/ocr-benchmark/：vision.swift 生成样例及测试 Apple 路径；engines.py 测试开源引擎；summarize.py 生成结果。运行时隔离在 ~/Library/Caches/NovaContextChecks/ocr-benchmark，未修改系统 Python、未安装 Homebrew、未复制运行库到 App。

- https://tesseract-ocr.github.io/tessdoc/Installation.html
- https://rapidai.github.io/RapidOCRDocs/main/en/install_usage/rapidocr/install/
- https://developer.apple.com/documentation/vision/vnrequest

详细文本、耗时、错误及模型 SHA-256 见 summary.json 和各引擎 JSON。
'''
(out/'README.md').write_text(text)
