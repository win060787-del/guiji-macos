#ifndef NOVA_NATIVE_OCR_H
#define NOVA_NATIVE_OCR_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
char *NovaOCRRecognizeRGBA(const uint8_t *pixels, int width, int height, int stride, const char *models, const char *languages);
void NovaOCRFreeText(char *text);
const char *NovaOCRVersion(void);
#ifdef __cplusplus
}
#endif
#endif
