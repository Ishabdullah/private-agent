Wake-word keyword-spotting model bundled in this directory is
`sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01` (the full-precision
release, NOT the `-mobile`/int8-quantized variant — see below for why), from
the [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) project
(Apache License 2.0), trained on the GigaSpeech corpus.

`keywords.txt` in this directory is generated at development time from the
5 wake phrases this app supports ("Hey Aigentik", "Hey Nova", "Hey Codey",
"Hey Juno", "Hey Milo") using the model's `bpe.model` via sentencepiece —
see `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md` for how to regenerate it
if the supported name list changes.

**Why full-precision, not int8**: the `-mobile` (int8-quantized) encoder
crashed the app deterministically and immediately on real hardware with
`Ort::Exception: ... Reshape node ... /downsample/Reshape_1 ... Input
shape:{17,1,128}, requested shape:{8,2,1,128}` — a genuine incompatibility
between this March-2024 quantized export and the sherpa-onnx 1.13.5 runtime
(confirmed via `adb logcat`/tombstone on a physical device, see progress
log). Swapping to the full-precision encoder/decoder/joiner from the same
model release fixed it. This makes the bundle ~14 MB instead of ~5.3 MB —
still small. If a future sherpa-onnx/model update makes the quantized
variant viable again, re-test on a real device before switching back;
Colab build verification alone did NOT catch this bug.
