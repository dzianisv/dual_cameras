#!/usr/bin/env python3
"""Host inference check for StoryCam multilingual captions.

Downloads the exact multilingual Whisper (base, int8) + Silero VAD files from
HuggingFace, verifies sizes and SHA-256 against the Hub tree API (LFS oids),
then decodes real test audio with sherpa-onnx and asserts:

  * Russian speech decodes to text containing
    one, two, three, four, five (один, два, три, четыре, пять)
  * detected language is Russian (ru)
  * token timestamps are non-empty, monotonic, and within the audio duration
  * silence (and VAD-gated noise) yields no words

The test speech is synthesized with espeak-ng in CI and is clearly labeled
as synthesized in the evidence. This is a host check only: it proves the
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
import sys
import urllib.request

BASE_REPO = "csukuangfj/sherpa-onnx-whisper-base"
VAD_REPO = "csukuangfj/vad"
FILES = [
    (BASE_REPO, "base-encoder.int8.onnx"),
    (BASE_REPO, "base-decoder.int8.onnx"),
    (BASE_REPO, "base-tokens.txt"),
    (VAD_REPO, "silero_vad.onnx"),
]
RU_WORDS = ["один", "два", "три", "четыре", "пять"]
EN_WORDS = ["one", "two", "three", "four", "five"]


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


def gate_words(words, segments, padding=0.15):
    """Mirror of the app's VAD gating: drop words with no overlap with any
    speech segment (expanded by padding); clamp the word end to the end of
    the speech segment it overlaps, so highlighting stops during silence."""
    kept = []
    for word in words:
        overlapping = [
            seg
            for seg in segments
            if word["start"] < seg[1] + padding and word["end"] > seg[0] - padding
        ]
        if not overlapping:
            continue
        seg_end = max(seg[1] for seg in overlapping)
        kept.append(
            {
                "text": word["text"],
                "start": word["start"],
                "end": min(word["end"], seg_end),
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
    args = parser.parse_args()

    import os

    import sherpa_onnx

    workdir = args.workdir
    os.makedirs(workdir, exist_ok=True)
    evidence: dict = {
        "speech": "synthesized with espeak-ng in CI (not a human recording)",
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
        wave = sherpa_onnx.read_wave(wav_path)
        assert wave.sample_rate == 16000, wave.sample_rate
        vad = sherpa_onnx.VoiceActivityDetector(
            vad_config, buffer_size_in_seconds=30
        )
        try:
            vad.accept_waveform(wave.samples)
            segments: list[tuple[float, float]] = []
            while not vad.is_empty():
                seg = vad.front()
                segments.append((float(seg.start), float(seg.end)))
                vad.pop()
            vad.flush()
            while not vad.is_empty():
                seg = vad.front()
                segments.append((float(seg.start), float(seg.end)))
                vad.pop()
            return segments
        finally:
            vad.free()

    try:
        whisper_config = sherpa_onnx.OfflineWhisperModelConfig(
            encoder=paths["base-encoder.int8.onnx"],
            decoder=paths["base-decoder.int8.onnx"],
            language="",
            task="transcribe",
            tail_paddings=-1,
            enable_token_timestamps=True,
        )
        timestamps_flag = True
    except TypeError as exc:
        print(f"NOTE: enable_token_timestamps unsupported: {exc}", flush=True)
        whisper_config = sherpa_onnx.OfflineWhisperModelConfig(
            encoder=paths["base-encoder.int8.onnx"],
            decoder=paths["base-decoder.int8.onnx"],
            language="",
            task="transcribe",
            tail_paddings=-1,
        )
        timestamps_flag = False
    evidence["timestamps_flag_supported"] = timestamps_flag
    recognizer = sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(
            model=sherpa_onnx.OfflineModelConfig(
                whisper=whisper_config,
                tokens=paths["base-tokens.txt"],
                model_type="whisper",
                num_threads=4,
            )
        )
    )

    def decode(wav_path: str) -> dict:
        wave = sherpa_onnx.read_wave(wav_path)
        duration = len(wave.samples) / wave.sample_rate
        stream = recognizer.create_stream()
        stream.accept_waveform(
            samples=wave.samples, sample_rate=wave.sample_rate
        )
        recognizer.decode(stream)
        result = recognizer.get_result(stream)
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
        all(w in lowered for w in RU_WORDS),
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
        all(w in " ".join(x["text"] for x in ru["gated_words"]).lower() for w in RU_WORDS),
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
        all(w in en["text"].lower() for w in EN_WORDS),
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
