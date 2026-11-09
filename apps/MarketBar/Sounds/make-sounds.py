"""Draws the two chimes as 16-bit WAV (standard library only): open rises (ding-DONG up), close falls.
Run: python3 Sounds/make-sounds.py  →  Sounds/market-open.wav, Sounds/market-close.wav"""
import math
import os
import struct
import wave

RATE = 44100


def bell(freq, start, length, total):
    """A soft bell: fundamental plus two partials, quick attack, exponential decay."""
    out = [0.0] * total
    for i in range(int(length * RATE)):
        t = i / RATE
        env = min(1.0, t / 0.005) * math.exp(-t * 3.2)
        v = math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 2.0 * t) * math.exp(-t * 4) \
            + 0.15 * math.sin(2 * math.pi * freq * 3.01 * t) * math.exp(-t * 6)
        j = int(start * RATE) + i
        if j < total:
            out[j] += v * env
    return out


def chime(notes, path):
    total = int(2.2 * RATE)
    mix = [0.0] * total
    for k, f in enumerate(notes):
        for i, v in enumerate(bell(f, k * 0.42, 1.6, total)):
            mix[i] += v
    peak = max(abs(v) for v in mix) or 1
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(v / peak * 0.8 * 32767)) for v in mix))


here = os.path.dirname(os.path.abspath(__file__))
chime([523.25, 783.99], os.path.join(here, "market-open.wav"))    # C5 → G5
chime([783.99, 523.25], os.path.join(here, "market-close.wav"))   # G5 → C5
