#!/usr/bin/env python3
"""Host inference check for StoryCam multilingual captions.

Downloads the exact multilingual Whisper (base, int8) + Silero VAD files from
HuggingFace, verifies sizes and SHA-256 against the Hub tree API (LFS oids),
then decodes real test audio with sherpa-onnx and asserts:

  * Russian speech decodes to text containing
    one, two, three, four, five — either as Cyrillic words
    (один, два, три, четыре, пять) or as digits ("1".."5"): Whisper's
    number normalization is run-to-run nondeterministic for isolated
    words (the Dart host test accepts either form for the same reason)
  * detected language is Russian (ru)
  * token timestamps are non-empty, monotonic, and within the audio duration
  * silence (and VAD-gated noise) yields no words

The test speech is the committed real-speech fixture
(packages/dual_cameras/example/test/fixtures/russian_numbers.wav: five
human Russian number clips from Wikimedia Commons, concatenated with 0.4s
silences) for Russian, with matching silence/noise fixtures; the English
sanity wav is synthesized with espeak-ng in CI and is clearly labeled as
synthesized in the evidence. This is a host check only: it proves the
model + decoder + VAD behave as the app needs. It does NOT prove anything
about Android (camera, mic, background work, burn-in) — that still needs a
phone.

Exit code 0 = all checks passed. Anything else = a failed check (message
names it). Evidence JSON is written to --out.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.request
import wave
from array import array

# Attention-enabled Whisper export (clairemcw): the csukuangfj decoder has
# no cross-attention outputs, so it cannot return token timestamps
# (sherpa-onnx warns "Timestamps will not be available"). Encoder and
# decoder are a matched pair — both come from this repo.
BASE_REPO = "clairemcw/sherpa-onnx-whisper-base-attention"
VAD_REPO = "csukuangfj/vad"
FILES = [
    (BASE_REPO, "base-encoder.int8.onnx"),
    (BASE_REPO, "base-decoder.int8.onnx"),
    (BASE_REPO, "base-tokens.txt"),
    (VAD_REPO, "silero_vad.onnx"),
]
# Each number as (Cyrillic word, digit): Whisper normalizes spoken numbers
# to digits on some runs and leaves Cyrillic on others, so either form
# counts (same accept-either rule as the Dart host inference test).
RU_WORDS = [
    ("один", "1"),
    ("два", "2"),
    ("три", "3"),
    ("четыре", "4"),
    ("пять", "5"),
]
EN_WORDS = [
    ("one", "1"),
    ("two", "2"),
    ("three", "3"),
    ("four", "4"),
    ("five", "5"),
]


def number_word_present(text: str, word: tuple[str, str]) -> bool:
    """True if the word form or its digit appears in text.

    The word form is matched as a substring (covers Cyrillic «один» and
    English "one"); the digit is matched as a standalone number token,
    so "1, 2, 3, 4, 5" (Whisper's comma-separated digit form) counts.
    """
    word_form, digit = word
    if word_form in text:
        return True
    return digit in re.findall(r"[0-9]+", text)


# Backwards-compatible name (the Russian checks used this first).
ru_word_present = number_word_present


def read_wave_16k_mono(path: str) -> array:
    """Read a 16 kHz mono wav as float32 samples in [-1, 1].

    Stdlib only (array/wave): sherpa-onnx 2.0.1 has no read_wave helper
    and numpy is not a declared dependency of the pip package, but the
    pybind11 bindings accept array.array('f') wherever a float32 tensor
    is expected (verified locally against 2.0.1).
    """
    with wave.open(path) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1, (
            f"{path}: expected 16 kHz mono, got "
            f"{w.getframerate()} Hz / {w.getnchannels()} ch"
        )
        raw = w.readframes(w.getnframes())
    pcm = array("h")
    pcm.frombytes(raw)
    out = array("f", [s / 32768.0 for s in pcm])
    return out


def hf_tree(repo: str) -> dict[str, dict]:
    url = f"https://huggingface.co/api/models/{repo}/tree/main"
    with urllib.request.urlopen(url, timeout=60) as resp:
        entries = json.load(resp)
    out: dict[str, dict] = {}
    for entry in entries:
        if entry.get("type") != "file":
            continue
        lfs = entry.get("lfs") or {}
        out[entry["path"]] = {
            "size": entry["size"],
            "lfs_oid": lfs.get("oid"),
        }
    return out


def download(url: str, dest: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    req = urllib.request.Request(url, headers={"User-Agent": "storycam-host-check/1.0"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(dest, "wb") as fh:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
            fh.write(chunk)
    return size, digest.hexdigest()


def aggregate_words(tokens, timestamps):
    """Mirror of Dart aggregateWords: 'Ġ' marks word starts, special tokens
    like <|0.00|> are skipped, word end = next word's start."""
    words = []
    current = ""
    current_start = 0.0

    def flush(end):
        text = current.strip()
        if text:
            words.append({"text": text, "start": current_start, "end": end})

    for i, tok in enumerate(tokens):
        if tok.startswith("<|") and tok.endswith("|>"):
            continue
        t = timestamps[i] if i < len(timestamps) else 0.0
        normalized = tok.replace("Ġ", " ")
        if normalized.startswith(" ") and current.strip():
            flush(t)
            current = ""
        if not current:
            current_start = t
        current += normalized
    if current.strip():
        last_t = timestamps[-1] if timestamps else 0.0
        flush(last_t + 0.4)
    for i in range(len(words) - 1):
        words[i]["end"] = words[i + 1]["start"]
    return words


def gate_words(words, segments, tolerance=0.05):
    """Mirror of Dart applyVadGate: drop words with no real overlap with any
    speech segment; clamp a kept word to the segment it overlaps most, so
    highlighting stops during silence. A word straddling a boundary is
    truncated to the segment, not dropped."""
    kept = []
    for word in words:
        best = None
        best_overlap = 0.0
        for seg in segments:
            overlap = min(word["end"], seg[1]) - max(word["start"], seg[0])
            if overlap > best_overlap:
                best_overlap = overlap
                best = seg
        if best is None or best_overlap <= tolerance:
            continue
        kept.append(
            {
                "text": word["text"],
                "start": max(word["start"], best[0]),
                "end": min(word["end"], best[1]),
            }
        )
    return kept


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workdir", required=True)
    parser.add_argument("--ru-wav", required=True)
    parser.add_argument("--en-wav", required=True)
    parser.add_argument("--silence-wav", required=True)
    parser.add_argument("--noise-wav", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--speech-label", default=None,
                        help="Label recorded in the evidence for the Russian "
                        "test speech (default: synthesized with espeak-ng).")
    args = parser.parse_args()

    import os

    import sherpa_onnx

    workdir = args.workdir
    os.makedirs(workdir, exist_ok=True)
    evidence: dict = {
        "speech": args.speech_label
        or "synthesized with espeak-ng in CI (not a human recording)",
        "sherpa_onnx_version": getattr(sherpa_onnx, "__version__", "unknown"),
        "files": [],
        "checks": {},
    }

    # 1. Download + verify model files against the Hub tree API.
    expected: dict[str, dict] = {}
    for repo in {BASE_REPO, VAD_REPO}:
        expected.update(hf_tree(repo))
    paths: dict[str, str] = {}
    for repo, name in FILES:
        url = f"https://huggingface.co/{repo}/resolve/main/{name}"
        dest = os.path.join(workdir, name)
        size, sha256 = download(url, dest)
        exp = expected[name]
        lfs_oid = exp["lfs_oid"]
        size_ok = size == exp["size"]
        # Git LFS oids ARE the SHA-256 of the file content; verify that claim
        # empirically instead of assuming it.
        hash_ok = lfs_oid is None or sha256 == lfs_oid
        evidence["files"].append(
            {
                "name": name,
                "repo": repo,
                "size": size,
                "expected_size": exp["size"],
                "size_ok": size_ok,
                "sha256": sha256,
                "lfs_oid": lfs_oid,
                "hash_ok": hash_ok,
            }
        )
        print(
            f"{name}: size={size} expected={exp['size']} size_ok={size_ok} "
            f"sha256={sha256} lfs_oid={lfs_oid} hash_ok={hash_ok}",
            flush=True,
        )
        if not size_ok or not hash_ok:
            print(f"FAIL: {name} failed size/hash verification", flush=True)
            evidence["checks"]["files_verified"] = False
            with open(args.out, "w", encoding="utf-8") as fh:
                json.dump(evidence, fh, indent=2, ensure_ascii=False)
            return 1
        paths[name] = dest
    evidence["checks"]["files_verified"] = True

    # 2. Build the VAD and the multilingual recognizer (language="" = auto).
    vad_config = sherpa_onnx.VadModelConfig(
        silero_vad=sherpa_onnx.SileroVadModelConfig(
            model=paths["silero_vad.onnx"],
            threshold=0.5,
            min_silence_duration=0.5,
            min_speech_duration=0.25,
            window_size=512,
        ),
        sample_rate=16000,
        num_threads=1,
        provider="cpu",
        debug=False,
    )

    def vad_segments(wav_path: str) -> list[tuple[float, float]]:
        samples = read_wave_16k_mono(wav_path)
        vad = sherpa_onnx.VoiceActivityDetector(
            vad_config, buffer_size_in_seconds=30
        )
        # The C SpeechSegment has start (a sample index) + samples; there is
        # no end field. Convert to seconds here, like the Dart detector.
        def to_seconds(seg) -> tuple[float, float]:
            start = seg.start / 16000
            end = (seg.start + len(seg.samples)) / 16000
            return (start, end)

        segments: list[tuple[float, float]] = []

        def drain() -> None:
            # NOTE: `empty` is a method in sherpa-onnx 2.0.1 Python
            # (`vad.empty()`), while `front` is a property.
            while not vad.empty():
                seg = vad.front
                segments.append(to_seconds(seg))
                vad.pop()

        # Feed in 512-sample windows (the VAD window size): feeding the
        # whole file at once returns only the last speech burst — the same
        # finding as the Dart detector fix (whole-feed VAD gave one
        # segment [6.534, 6.848] for the five-word fixture).
        for i in range(0, len(samples), 512):
            vad.accept_waveform(samples[i : i + 512])
            drain()
        vad.flush()
        drain()
        return sorted(segments)

    # sherpa-onnx 2.0.1 Python has no public OfflineRecognizerConfig
    # constructor (OfflineRecognizer() takes no arguments) — the factory
    # OfflineRecognizer.from_whisper is the API (verified locally).
    try:
        recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=paths["base-encoder.int8.onnx"],
            decoder=paths["base-decoder.int8.onnx"],
            tokens=paths["base-tokens.txt"],
            language="",
            task="transcribe",
            num_threads=4,
            tail_paddings=-1,
            enable_token_timestamps=True,
        )
        timestamps_flag = True
    except TypeError as exc:
        print(f"NOTE: enable_token_timestamps unsupported: {exc}", flush=True)
        recognizer = sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=paths["base-encoder.int8.onnx"],
            decoder=paths["base-decoder.int8.onnx"],
            tokens=paths["base-tokens.txt"],
            language="",
            task="transcribe",
            num_threads=4,
            tail_paddings=-1,
        )
        timestamps_flag = False
    evidence["timestamps_flag_supported"] = timestamps_flag

    def decode(wav_path: str) -> dict:
        samples = read_wave_16k_mono(wav_path)
        duration = len(samples) / 16000
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, samples)
        recognizer.decode_stream(stream)
        result = stream.result
        tokens = list(result.tokens)
        timestamps = [float(t) for t in result.timestamps]
        words = aggregate_words(tokens, timestamps)
        segments = vad_segments(wav_path)
        gated = gate_words(words, segments)
        return {
            "duration": duration,
            "text": result.text,
            "lang": result.lang,
            "tokens": tokens,
            "timestamps": timestamps,
            "words": words,
            "vad_segments": segments,
            "gated_words": gated,
        }

    failures: list[str] = []

    def check(name: str, ok: bool, detail: str = "") -> None:
        evidence["checks"][name] = ok
        print(f"{'PASS' if ok else 'FAIL'}: {name} {detail}", flush=True)
        if not ok:
            failures.append(name)

    # 3. Russian.
    ru = decode(args.ru_wav)
    evidence["russian"] = {
        k: ru[k]
        for k in ("duration", "text", "lang", "words", "vad_segments", "gated_words")
    }
    evidence["russian"]["timestamps_sample"] = ru["timestamps"][:10]
    evidence["russian"]["timestamp_count"] = len(ru["timestamps"])
    evidence["russian"]["token_count"] = len(ru["tokens"])
    print(f"RU text: {ru['text']!r} lang={ru['lang']!r}", flush=True)
    print(f"RU words: {ru['words']}", flush=True)
    print(f"RU VAD segments: {ru['vad_segments']}", flush=True)
    lowered = ru["text"].lower()
    check(
        "russian_text",
        all(ru_word_present(lowered, w) for w in RU_WORDS),
        f"text={ru['text']!r}",
    )
    check("russian_lang", ru["lang"] == "ru", f"lang={ru['lang']!r}")
    ts = ru["timestamps"]
    ts_ok = (
        len(ts) > 0
        and all(ts[i] <= ts[i + 1] for i in range(len(ts) - 1))
        and all(0.0 <= t <= ru["duration"] + 0.01 for t in ts)
    )
    check(
        "russian_timestamps",
        ts_ok,
        f"count={len(ts)} sample={ts[:5]} duration={ru['duration']:.2f}",
    )
    check(
        "russian_gated_words",
        all(
            ru_word_present(
                " ".join(x["text"] for x in ru["gated_words"]).lower(), w
            )
            for w in RU_WORDS
        ),
        f"gated={ru['gated_words']}",
    )

    # 4. English (sanity: auto-detect must not force Russian).
    en = decode(args.en_wav)
    evidence["english"] = {
        k: en[k]
        for k in ("duration", "text", "lang", "words", "vad_segments", "gated_words")
    }
    print(f"EN text: {en['text']!r} lang={en['lang']!r}", flush=True)
    check("english_lang", en["lang"] == "en", f"lang={en['lang']!r}")
    check(
        "english_text",
        # espeak says "one, two, ..." but Whisper may normalize to
        # digits ("1, 2, 3, 4, 5") — same accept-either rule as Russian.
        all(number_word_present(en["text"].lower(), w) for w in EN_WORDS),
        f"text={en['text']!r}",
    )

    # 5. Silence: VAD must find no speech and the gated result must be empty.
    # The raw Whisper text is recorded as evidence: if it hallucinates, the
    # VAD gate is what saves us, and the gated result must still be empty.
    silence = decode(args.silence_wav)
    evidence["silence"] = {
        k: silence[k]
        for k in ("duration", "text", "lang", "words", "vad_segments", "gated_words")
    }
    print(
        f"SILENCE raw text: {silence['text']!r} words={silence['words']} "
        f"vad={silence['vad_segments']}",
        flush=True,
    )
    check("silence_no_vad_speech", silence["vad_segments"] == [])
    check("silence_no_words", silence["gated_words"] == [])

    # 6. Low pink noise: same bar as silence (gated result empty).
    noise = decode(args.noise_wav)
    evidence["noise"] = {
        k: noise[k]
        for k in ("duration", "text", "lang", "words", "vad_segments", "gated_words")
    }
    print(
        f"NOISE raw text: {noise['text']!r} words={noise['words']} "
        f"vad={noise['vad_segments']}",
        flush=True,
    )
    check("noise_no_words", noise["gated_words"] == [])

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(evidence, fh, indent=2, ensure_ascii=False)
    if failures:
        print(f"FAILED checks: {failures}", flush=True)
        return 1
    print("ALL HOST INFERENCE CHECKS PASSED", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
