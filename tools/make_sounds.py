#!/usr/bin/env python3
"""Writes the crowd, the horn, the falling water and the announcer into audio/*.ogg.

    python3 -I tools/make_sounds.py [--kenney DIR]

THIS SCRIPT IS THE SOURCE of every sound it writes, and the .ogg files are committed: a server
and a browser get files, never this. Re-run it after changing a recipe, listen, commit both.

- The crowd (cheer, gasp, roar), the stadium horn and the falling water are SYNTHESISED here
  from fixed seeds, so they are this repository's own work (MIT, like the code), and the same
  bytes every run on the same numpy.
- The announcer's voice lines are COPIED from Kenney's "Voiceover Pack" and "Voiceover Pack Fighter" (CC0 1.0,
  kenney.nl, credited in the README): a person saying "three, two, one, go" is the one sound
  nothing here can synthesise convincingly. --kenney points at the unpacked bundle's
  Audio/ directory (default: the family's copy, ~/stack/game-dev/assets/kenny-assets/Audio).

Needs numpy, scipy and ffmpeg (libvorbis). Loudness is levelled to about -16 LUFS so a cheer
does not drown the machinery a runner listens for; the peak stays under -1 dBFS.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import wave

import numpy as np
from scipy import signal

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio")

# id -> Kenney file (Voiceover Pack, male voice; the fighter pack's "winner" for the first home).
VOICE = {
    "voice_3": "Voiceover Pack/Audio (Male)/3.ogg",
    "voice_2": "Voiceover Pack/Audio (Male)/2.ogg",
    "voice_1": "Voiceover Pack/Audio (Male)/1.ogg",
    "voice_go": "Voiceover Pack/Audio (Male)/go.ogg",
    "voice_hurry": "Voiceover Pack/Audio (Male)/hurry_up.ogg",
    "voice_time_over": "Voiceover Pack/Audio (Male)/time_over.ogg",
    "voice_final": "Voiceover Pack/Audio (Male)/final_round.ogg",
    "voice_congratulations": "Voiceover Pack/Audio (Male)/congratulations.ogg",
    "voice_you_win": "Voiceover Pack/Audio (Male)/you_win.ogg",
    "voice_you_lose": "Voiceover Pack/Audio (Male)/you_lose.ogg",
    "voice_winner": "Voiceover Pack Fighter/Audio/winner.ogg",
}


def bandpass(x, low, high, order=2):
    sos = signal.butter(order, [low, high], btype="bandpass", fs=RATE, output="sos")
    return signal.sosfilt(sos, x)


def lowpass(x, cut, order=2):
    sos = signal.butter(order, cut, btype="lowpass", fs=RATE, output="sos")
    return signal.sosfilt(sos, x)


def envelope(n, attack, release, start=0, length=None):
    """A trapezoid: up over `attack` s from `start`, held, down over `release` s at the end."""
    env = np.zeros(n)
    length = n - start if length is None else min(length, n - start)
    a = max(int(attack * RATE), 1)
    r = max(int(release * RATE), 1)
    seg = np.ones(length)
    seg[:min(a, length)] = np.linspace(0.0, 1.0, min(a, length))
    if r < length:
        seg[-r:] *= np.linspace(1.0, 0.0, r)
    env[start:start + length] = seg
    return env


def voice(rng, n, f0, formants, glide=0.0, start=0, length=None):
    """One person: a buzzing vocal tone with vibrato, through two vowel formants."""
    t = np.arange(n) / RATE
    vib = 1.0 + 0.025 * np.sin(2 * np.pi * rng.uniform(4.5, 7.0) * t + rng.uniform(0, 6.28))
    f = f0 * vib * (1.0 + glide * t / max(t[-1], 1e-3))
    phase = 2 * np.pi * np.cumsum(f) / RATE
    buzz = signal.sawtooth(phase) * 0.6 + rng.normal(0, 0.15, n)
    out = np.zeros(n)
    for (lo, hi), gain in formants:
        out += bandpass(buzz, lo, hi) * gain
    attack = rng.uniform(0.05, 0.25)
    return out * envelope(n, attack, rng.uniform(0.3, 0.8), start, length)


def claps(rng, n, density, start=0.0, end=None):
    out = np.zeros(n)
    end = n / RATE if end is None else end
    count = int(density * (end - start))
    clap = np.exp(-np.arange(int(0.03 * RATE)) / (0.006 * RATE))
    for _ in range(count):
        at = int(rng.uniform(start, end) * RATE)
        burst = rng.normal(0, 1, clap.size) * clap * rng.uniform(0.3, 1.0)
        stop = min(at + burst.size, n)
        out[at:stop] += burst[:stop - at]
    return bandpass(out, 700, 5000)


def stereo(rng, layers):
    """Pans each mono layer somewhere left to right and sums them."""
    n = max(layer.size for layer in layers)
    left = np.zeros(n)
    right = np.zeros(n)
    for layer in layers:
        pan = rng.uniform(0.15, 0.85)
        left[:layer.size] += layer * np.cos(pan * np.pi / 2)
        right[:layer.size] += layer * np.sin(pan * np.pi / 2)
    return np.stack([left, right], axis=1)


AH = [((650, 900), 1.0), ((1100, 1500), 0.7)]
EH = [((450, 650), 1.0), ((1700, 2200), 0.55)]
OO = [((260, 420), 1.0), ((700, 1000), 0.45)]


def cheer(seed=11, seconds=2.8):
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    layers = []
    for _ in range(42):
        f0 = rng.uniform(150, 360)
        start = int(rng.uniform(0.0, 0.35) * RATE)
        length = int(rng.uniform(1.4, seconds) * RATE)
        layers.append(voice(rng, n, f0, AH if rng.uniform() < 0.6 else EH, glide=rng.uniform(0.0, 0.12),
                            start=start, length=length) * rng.uniform(0.4, 1.0))
    # A few whistles and "woo"s over the top.
    t = np.arange(n) / RATE
    for _ in range(4):
        f = rng.uniform(1500, 2400) * (1.0 + 0.25 * np.sin(2 * np.pi * rng.uniform(0.3, 0.9) * t))
        start = int(rng.uniform(0.2, 1.2) * RATE)
        whistle = np.sin(2 * np.pi * np.cumsum(f) / RATE) * envelope(n, 0.05, 0.2, start, int(0.6 * RATE))
        layers.append(whistle * 0.12)
    layers.append(claps(rng, n, 160, 0.1, seconds - 0.2) * 0.5)
    roar = bandpass(rng.normal(0, 1, n), 300, 3000) * envelope(n, 0.3, 1.0) * 0.25
    layers.append(roar)
    return stereo(rng, layers)


def gasp(seed=12, seconds=1.7):
    """The crowd watching somebody go in: a falling "ooh"."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    layers = []
    for _ in range(36):
        f0 = rng.uniform(170, 380)
        start = int(rng.uniform(0.0, 0.15) * RATE)
        layers.append(voice(rng, n, f0, OO, glide=-rng.uniform(0.15, 0.3), start=start,
                            length=int(rng.uniform(1.0, seconds) * RATE)) * rng.uniform(0.4, 1.0))
    return stereo(rng, layers)


def roar(seed=13, seconds=3.6):
    """Applause and a roar: the big moments (a winner home, the final death starting)."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    layers = [claps(rng, n, 420, 0.0, seconds - 0.3) * 0.9]
    for _ in range(30):
        layers.append(voice(rng, n, rng.uniform(140, 330), AH, glide=rng.uniform(-0.05, 0.1),
                            start=int(rng.uniform(0, 0.6) * RATE)) * rng.uniform(0.25, 0.7))
    layers.append(bandpass(rng.normal(0, 1, n), 250, 2500) * envelope(n, 0.4, 1.2) * 0.3)
    return stereo(rng, layers)


def horn(seed=14, seconds=1.3):
    """The stadium horn that opens the gate: three brassy tones, a little apart."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for f in (233.1, 293.7, 349.2):
        detune = 1.0 + rng.uniform(-0.004, 0.004)
        out += signal.sawtooth(2 * np.pi * f * detune * t) + 0.5 * signal.square(2 * np.pi * f * 0.5 * detune * t)
    out = lowpass(out, 2600, 4) * envelope(n, 0.02, 0.25)
    return np.stack([out, out], axis=1)


def water(seed=15, seconds=1.4):
    """A sluice opening: a rush that swells in, then the splash on the deck."""
    rng = np.random.default_rng(seed)
    n = int(seconds * RATE)
    noise = rng.normal(0, 1, n)
    rush = bandpass(noise, 200, 5000) * envelope(n, 0.25, 0.6)
    hiss = bandpass(rng.normal(0, 1, n), 2500, 9000) * envelope(n, 0.4, 0.5, int(0.2 * RATE)) * 0.4
    splash = bandpass(rng.normal(0, 1, n), 400, 3000) * envelope(n, 0.01, 0.5, int(0.28 * RATE),
                                                               int(0.7 * RATE)) * 0.8
    return stereo(rng, [rush, hiss, splash])


def level(audio, target_rms_db=-19.0, peak_db=-1.0):
    rms = np.sqrt(np.mean(audio ** 2)) + 1e-9
    audio = audio * (10 ** (target_rms_db / 20) / rms)
    peak = np.max(np.abs(audio)) + 1e-9
    limit = 10 ** (peak_db / 20)
    if peak > limit:
        audio = audio * (limit / peak)
    return audio


def write_ogg(name, audio):
    os.makedirs(OUT, exist_ok=True)
    audio = level(audio)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, name + ".wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(audio.shape[1])
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
        target = os.path.join(OUT, name + ".ogg")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", path, "-c:a", "libvorbis", "-q:a", "4",
                        "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", target],
                       check=True)
    print("wrote audio/%s.ogg" % name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kenney", default=os.path.expanduser("~/stack/game-dev/assets/kenny-assets/Audio"))
    args = parser.parse_args()

    write_ogg("crowd_cheer", cheer())
    write_ogg("crowd_gasp", gasp())
    write_ogg("crowd_roar", roar())
    write_ogg("air_horn", horn())
    write_ogg("machine_fall", water())

    missing = []
    for name, rel in VOICE.items():
        source = os.path.join(args.kenney, rel)
        if not os.path.exists(source):
            missing.append(source)
            continue
        shutil.copyfile(source, os.path.join(OUT, name + ".ogg"))
        print("copied audio/%s.ogg (Kenney, CC0)" % name)

    # Each pack's licence beside the files it came from (CC0; credited in the README).
    for pack, name in (("Voiceover Pack", "LICENSE-kenney-voiceover-pack.txt"),
                       ("Voiceover Pack Fighter", "LICENSE-kenney-voiceover-pack-fighter.txt")):
        licence = os.path.join(args.kenney, pack, "License.txt")
        if os.path.exists(licence):
            shutil.copyfile(licence, os.path.join(OUT, name))

    if missing:
        print("not found (voice lines kept as they are):\n  " + "\n  ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
