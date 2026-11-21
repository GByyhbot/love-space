"""2.7.0 语音转文字（ASR）· SenseVoiceSmall 引擎封装（后端先行）。

部署形态（提示词第③项第 0 步实测定案）：
- 模型：sherpa-onnx SenseVoiceSmall int8（model.int8.onnx + tokens.txt），
  放 NAS 数据卷 DATA/asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
  （不进镜像）；缺失时 is_ready()=False → 端点 503「识别模型未就绪」。
- 依赖：sherpa-onnx 进 requirements.txt 进镜像；NAS 实测 RTF≈0.12（N100
  2 线程，远低于 0.5 红线）。
- 执行：**子进程**转写（asr_worker.py），60s 硬超时可强杀，不阻塞事件循环
  与其它接口；单飞队列（模块级 Lock）保证同一时刻只跑一条，其余排队。
- m4a/aac 等非 PCM 输入先经 ffmpeg 转 16k mono wav 临时文件（NAS 已有
  ffmpeg），wav 直传免转。

测试替身：transcribe_file() 是唯一引擎入口，pytest 通过 monkeypatch 替换，
不依赖真实模型与 NAS 环境。
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid
import wave
from pathlib import Path

from . import db

# 模型目录（DATA/asr/<包名>）；测试可经环境变量覆盖
MODEL_REL = 'asr/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17'
TRANSCRIBE_TIMEOUT = 60
MAX_BYTES = 10 * 1024 * 1024
# 单飞：同一时刻只跑一条转写，其余排队（提示词第③项 2）
_gate = threading.Lock()

_engine_lock = threading.Lock()
_engine_probe_done = False


def model_dir():
    """模型目录绝对路径（支持测试环境变量覆盖）。"""
    override = os.environ.get('ASR_MODEL_DIR')
    if override:
        return Path(override)
    return db.DATA / MODEL_REL


def is_ready():
    """模型与依赖是否就绪（tokens/model 文件存在）。每次调用都查（轻量 stat）。"""
    d = model_dir()
    return (d / 'model.int8.onnx').is_file() and (d / 'tokens.txt').is_file()


def _ffmpeg_to_wav(src: Path, dst: Path):
    """任意音频输入 → 16k mono PCM wav（sherpa 只吃 PCM）。ffmpeg 缺失抛错。"""
    if shutil.which('ffmpeg') is None:
        raise RuntimeError('ffmpeg 不可用')
    subprocess.run(
        ['ffmpeg', '-y', '-i', str(src), '-ac', '1', '-ar', '16000',
         '-sample_fmt', 's16', str(dst)],
        capture_output=True, timeout=60, check=True)


def _wav_frames(path: Path):
    w = wave.open(str(path), 'rb')
    sr = w.getframerate()
    n = w.getnframes()
    raw = w.readframes(n)
    w.close()
    return sr, raw


def _run_engine(wav_path: Path, tmpdir: Path) -> str:
    """子进程转写：60s 硬超时可强杀；结果经 stdout JSON 传回。

    依赖路径：镜像 requirements.txt 装 sherpa-onnx；本机/NAS 手测环境的
    PYTHONPATH 注入由调用方（脚本/部署侧）自理。
    """
    out_json = tmpdir / (uuid.uuid4().hex + '.json')
    env = dict(os.environ)
    env['ASR_WAV'] = str(wav_path)
    env['ASR_MODEL'] = str(model_dir())
    env['ASR_OUT'] = str(out_json)
    # 引擎依赖在 /data/asr/pylib（容器实测路径），存在则注入
    pylib = model_dir().parent / 'pylib'
    if pylib.is_dir():
        env['PYTHONPATH'] = str(pylib) + os.pathsep + env.get('PYTHONPATH', '')
    script = Path(__file__).parent / 'asr_worker.py'
    subprocess.run([sys.executable, str(script)], env=env,
                   capture_output=True, timeout=TRANSCRIBE_TIMEOUT, check=True)
    text = json.loads(out_json.read_text(encoding='utf-8')).get('text', '')
    out_json.unlink(missing_ok=True)
    return text.strip()


def transcribe_file(src: Path) -> str:
    """唯一引擎入口（测试替身挂这里）：入参任意音频文件 → 转写文本。

    单飞 + 60s 硬超时；wav 直用，其余先 ffmpeg 转 16k mono wav。
    """
    if not is_ready():
        raise ModelNotReady()
    src = Path(src)
    with _gate:
        tmpdir = Path(tempfile.mkdtemp(prefix='asr-'))
        try:
            if src.suffix.lower() == '.wav':
                wav = tmpdir / 'in.wav'
                shutil.copyfile(src, wav)
            else:
                wav = tmpdir / 'in.wav'
                _ffmpeg_to_wav(src, wav)
            # 快速截掉空文件：无帧直接返回空文本
            try:
                _wav_frames(wav)
            except Exception:
                return ''
            return _run_engine(wav, tmpdir)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


class ModelNotReady(Exception):
    """模型未就绪（目录缺失）——端点转 503。"""
