# Native offline OCR fallback

Apple Vision remains the primary OCR engine. An exception or empty result falls back to Tesseract 5.5.3. Both receive the same rasterized page; all processing stays in the app. Recognition never changes the source document. The existing conversion preview and explicit Markdown export remain in place.

## Rebuild

Run `python3 scripts/build-native-ocr.py --cmake /path/to/cmake` from Demo on a Mac with Xcode command-line tools and CMake installed. The script verifies pinned source archives and six model hashes from `manifest.json`, builds static arm64 libraries for macOS 14+, and regenerates `Vendor/NativeOCR.xcframework`. A writable cache outside the checkout holds build output. Build-time Internet access is required only for uncached pinned sources/models; runtime needs no download, Python, Homebrew, subprocess, or network permission.

Leptonica image codecs, Tesseract curl/archive, OpenMP, training tools and graphics are disabled. ImageIO supplies RGBA pixels. Tesseract debug-font generation is disabled; upstream in-memory image serialization may print missing-PNG warnings and use BMP instead. It does not require PNG decoding in Leptonica. Full licenses are under Packaging/Licenses and ContextCore resource licenses.

## Boundaries

The models support English, Simplified Chinese, Traditional Chinese, Japanese, Spanish and Turkish. This is plain-text OCR, not reliable table/layout reconstruction. The combined multilingual recognizer may insert spaces, confuse code punctuation, or mix simplified/traditional characters. Preview and manual verification remain necessary. Vision failure can still delay fallback until its synchronous request returns; cancellation is honored between engines and pages, not during a synchronous native OCR call. The previous benchmark using per-fixture language hints is not a quality or speed guarantee for the combined production recognizer.

No App Store upload or submission is performed by this script.
