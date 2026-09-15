#!/usr/bin/env python3
"""iOS アプリ同梱の通知音 (.caf) を合成する。

使い方: python3 app-ios/tools/gen-sounds.py
  → app-ios/PromptRelay/PromptRelay/Sounds/*.caf を再生成する
依存: numpy, afconvert (macOS 標準)

iOS のカスタム通知音はアプリ bundle 内の 30 秒以下の音声ファイルだけが使えるため、
システム音を流用せずここで生成する。音の一覧は NotificationSoundSettings.swift と
対応している (rawValue = ファイル名の拡張子抜き)。
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "PromptRelay", "PromptRelay", "Sounds")


def t(sec):
    return np.arange(int(SR * sec)) / SR


def env(n, attack=0.005, decay=0.5):
    """短いアタック + 指数減衰。"""
    x = np.arange(n) / SR
    e = np.exp(-x / decay)
    a = int(SR * attack)
    if a > 0:
        e[:a] *= np.linspace(0, 1, a)
    return e


def tone(freq, sec, partials=((1, 1.0),), decay=0.5):
    x = t(sec)
    y = np.zeros_like(x)
    for mult, amp in partials:
        y += amp * np.sin(2 * np.pi * freq * mult * x)
    return y * env(len(x), decay=decay)


def place(buf, y, at):
    s = int(SR * at)
    e = min(len(buf), s + len(y))
    buf[s:e] += y[: e - s]


def chime():
    # 2 音のチャイム (E6 → C6)
    buf = np.zeros(int(SR * 1.2))
    p = ((1, 1.0), (2, 0.25), (3, 0.08))
    place(buf, tone(1318.5, 1.0, p, decay=0.35), 0.0)
    place(buf, tone(1046.5, 1.0, p, decay=0.45), 0.32)
    return buf


def bell():
    # 非整数倍音のベル 1 打
    buf = np.zeros(int(SR * 1.6))
    p = ((1, 1.0), (2.0, 0.5), (2.76, 0.35), (4.07, 0.2), (5.4, 0.1))
    place(buf, tone(880.0, 1.6, p, decay=0.5), 0.0)
    return buf


def pop():
    # ピッチが下がる短いブリップ
    x = t(0.18)
    f = 900 * np.exp(-x * 12) + 500
    phase = 2 * np.pi * np.cumsum(f) / SR
    y = np.sin(phase) + 0.3 * np.sin(2 * phase)
    return y * env(len(x), attack=0.002, decay=0.06)


def triple():
    # 上昇する短い 3 連ビープ (C5 E5 G5)
    buf = np.zeros(int(SR * 0.7))
    p = ((1, 1.0), (2, 0.3))
    for i, f in enumerate((523.25, 659.25, 783.99)):
        place(buf, tone(f, 0.18, p, decay=0.08), i * 0.16)
    return buf


def marimba():
    # 木質のアルペジオ (C5 E5 G5 C6)
    buf = np.zeros(int(SR * 0.9))
    p = ((1, 1.0), (4, 0.35), (10, 0.05))
    for i, f in enumerate((523.25, 659.25, 783.99, 1046.5)):
        place(buf, tone(f, 0.4, p, decay=0.12), i * 0.13)
    return buf


def pulse():
    # 2 連の太めのパルス (注意喚起向け)
    buf = np.zeros(int(SR * 0.6))
    p = ((1, 1.0), (2, 0.6), (3, 0.25), (4, 0.1))
    for at in (0.0, 0.22):
        place(buf, tone(440.0, 0.2, p, decay=0.09), at)
    return buf


SOUNDS = {
    "chime": chime,
    "bell": bell,
    "pop": pop,
    "triple": triple,
    "marimba": marimba,
    "pulse": pulse,
}


def write_caf(name, y):
    y = y / max(1e-9, np.max(np.abs(y))) * 0.8
    fade = int(SR * 0.01)
    y[-fade:] *= np.linspace(1, 0, fade)
    pcm = (y * 32767).astype(np.int16)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    out = os.path.join(OUT_DIR, f"{name}.caf")
    subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav_path, out], check=True)
    os.unlink(wav_path)
    print(f"{out}: {len(y) / SR:.2f}s")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, fn in SOUNDS.items():
        write_caf(name, fn())


if __name__ == "__main__":
    sys.exit(main())
