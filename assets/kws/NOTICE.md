Wake-word keyword-spotting model bundled in this directory is
`sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01-mobile`, from the
[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) project
(Apache License 2.0), trained on the GigaSpeech corpus.

`keywords.txt` in this directory is generated at development time from the
5 wake phrases this app supports ("Hey Aigentik", "Hey Nova", "Hey Codey",
"Hey Juno", "Hey Milo") using the model's `bpe.model` via sentencepiece —
see `docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md` for how to regenerate it
if the supported name list changes.
