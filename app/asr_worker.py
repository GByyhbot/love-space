"""2.7.0 ASR 子进程 worker：读 ASR_WAV → SenseVoice 转写 → 写 ASR_OUT（JSON）。

独立进程执行，主进程 60s 超时可强杀；依赖经 PYTHONPATH 注入（容器实测
/data/asr/pylib）。任何失败以非零退出/无输出文件表达，调用方捕获。
"""
import json
import os
import wave

model = os.environ['ASR_MODEL']
tokens = os.path.join(model, 'tokens.txt')
model_file = os.path.join(model, 'model.int8.onnx')

import sherpa_onnx  # noqa: E402

rec = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model=model_file, tokens=tokens, use_itn=True, num_threads=2)

wav_path = os.environ['ASR_WAV']
w = wave.open(wav_path, 'rb')
sr = w.getframerate()
n = w.getnframes()
raw = w.readframes(n)
w.close()

import struct  # noqa: E402

count = len(raw) // 2
samples = list(struct.unpack('<' + 'h' * count, raw)) if count else []

s = rec.create_stream()
s.accept_waveform(sr, samples)
rec.decode_stream(s)

out = os.environ['ASR_OUT']
with open(out, 'w', encoding='utf-8') as f:
    json.dump({'text': s.result.text}, f, ensure_ascii=False)
