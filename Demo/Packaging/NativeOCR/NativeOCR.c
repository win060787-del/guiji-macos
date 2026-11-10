#include "NativeOCR.h"
#include <tesseract/capi.h>

char *NovaOCRRecognizeRGBA(const uint8_t *pixels, int width, int height, int stride, const char *models, const char *languages) {
    if (!pixels || !models || !languages || width <= 0 || height <= 0 || width > 4096 || height > 4096 || stride != width * 4) return 0;
    TessBaseAPI *api = TessBaseAPICreate();
    if (!api) return 0;
    if (TessBaseAPIInit3(api, models, languages) != 0) { TessBaseAPIDelete(api); return 0; }
    TessBaseAPISetVariable(api, "debug_file", "/dev/null");
    TessBaseAPISetPageSegMode(api, PSM_AUTO);
    TessBaseAPISetImage(api, pixels, width, height, 4, stride);
    TessBaseAPISetSourceResolution(api, 200);
    char *text = TessBaseAPIRecognize(api, 0) == 0 ? TessBaseAPIGetUTF8Text(api) : 0;
    TessBaseAPIDelete(api);
    return text;
}
void NovaOCRFreeText(char *text) { if (text) TessDeleteText(text); }
const char *NovaOCRVersion(void) { return TessVersion(); }
