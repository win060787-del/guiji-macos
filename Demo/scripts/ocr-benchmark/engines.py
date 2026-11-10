"""Local synthetic-fixture benchmark. Never loads user documents or production credentials."""
import ctypes,glob,json,os,resource,statistics,sys,time
from pathlib import Path
from PIL import Image
mode=sys.argv[1];root=Path(sys.argv[2]);fixtures=json.loads((root/'manifest.json').read_text())
def emit(v):print(json.dumps(v,ensure_ascii=False),flush=True)
if mode=='tesseract':
    env=Path(sys.executable).resolve().parents[1]
    lib=ctypes.CDLL(str(env/'lib/libtesseract.dylib'))
    lib.TessBaseAPICreate.restype=ctypes.c_void_p
    lib.TessBaseAPIInit3.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p];lib.TessBaseAPIInit3.restype=ctypes.c_int
    lib.TessBaseAPISetPageSegMode.argtypes=[ctypes.c_void_p,ctypes.c_int]
    lib.TessBaseAPISetImage.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_int]
    lib.TessBaseAPIRecognize.argtypes=[ctypes.c_void_p,ctypes.c_void_p];lib.TessBaseAPIRecognize.restype=ctypes.c_int
    lib.TessBaseAPIGetUTF8Text.argtypes=[ctypes.c_void_p];lib.TessBaseAPIGetUTF8Text.restype=ctypes.c_void_p
    lib.TessDeleteText.argtypes=[ctypes.c_void_p];lib.TessBaseAPIDelete.argtypes=[ctypes.c_void_p]
    lib.TessVersion.restype=ctypes.c_char_p
    languages={'zh-Hans':'chi_sim+eng','zh-Hant':'chi_tra+eng','en-US':'eng','ja-JP':'jpn+eng','es-ES':'spa+eng','tr-TR':'tur+eng'}
    handle=None;previous=None
    for item in fixtures:
        start=time.perf_counter()
        try:
            lang=languages[item['language']]
            if lang!=previous:
                if handle:lib.TessBaseAPIDelete(handle)
                handle=lib.TessBaseAPICreate()
                if lib.TessBaseAPIInit3(handle,str(env/'share/tessdata').encode(),lang.encode())!=0:raise RuntimeError('model init failed')
                lib.TessBaseAPISetPageSegMode(handle,6);previous=lang
            setup=time.perf_counter()-start
            image=Image.open(root/item['file']).convert('RGB');data=image.tobytes();buffer=ctypes.create_string_buffer(data)
            durations=[];text=''
            for _ in range(3):
                t=time.perf_counter();lib.TessBaseAPISetImage(handle,buffer,image.width,image.height,3,image.width*3)
                if lib.TessBaseAPIRecognize(handle,None)!=0:raise RuntimeError('recognition failed')
                ptr=lib.TessBaseAPIGetUTF8Text(handle)
                if not ptr:raise RuntimeError('empty output pointer')
                text=ctypes.string_at(ptr).decode();lib.TessDeleteText(ptr);durations.append(time.perf_counter()-t)
            emit({'id':item['id'],'engine':mode,'ok':True,'text':text,'warm_median_seconds':statistics.median(durations[1:]),'first_seconds':durations[0],'setup_seconds':setup,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'language_hint':lang,'version':lib.TessVersion().decode()})
        except Exception as e:emit({'id':item['id'],'engine':mode,'ok':False,'error':str(e)})
    if handle:lib.TessBaseAPIDelete(handle)
elif mode=='rapidocr':
    from rapidocr import RapidOCR
    from importlib.metadata import version
    start=time.perf_counter()
    engine=RapidOCR(params={'Global.log_level':'error','EngineConfig.onnxruntime.intra_op_num_threads':2,'EngineConfig.onnxruntime.inter_op_num_threads':1,'EngineConfig.onnxruntime.use_coreml':False})
    setup=time.perf_counter()-start
    for item in fixtures:
        try:
            durations=[];text=''
            for _ in range(3):
                t=time.perf_counter();result=engine(str(root/item['file']));durations.append(time.perf_counter()-t)
                text='\n'.join(result.txts or [])
            emit({'id':item['id'],'engine':mode,'ok':True,'text':text,'warm_median_seconds':statistics.median(durations[1:]),'first_seconds':durations[0],'setup_seconds':setup,'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'version':version('rapidocr'),'onnxruntime_version':version('onnxruntime'),'models':'PP-OCRv6 det small + rec small; PP-OCRv4 classifier; CPU provider; threads2/1'})
            setup=0
        except Exception as e:emit({'id':item['id'],'engine':mode,'ok':False,'error':str(e)})
