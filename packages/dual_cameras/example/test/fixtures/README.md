# Test fixtures for the host inference check (`test/host_inference_test.dart`)
# and the Python host check (`tools/host_inference_check.py`).

## russian_numbers.wav — 6.850 s, 16 kHz mono s16
SHA-256: `e8a722f0e4d8cc0d0854f91d6ebf8b7286b0ebbde843e2e4d2bb5a038bd7a1b4`

Five real human Russian number clips from Wikimedia Commons, each
normalized to 16 kHz mono and concatenated with 0.4 s of digital silence
between words:

| word | source file | duration | source SHA-256 (as downloaded) |
| --- | --- | --- | --- |
| один | `Ru-один.ogg` | 1.097 s | `e74ff9e4150edadabf54f09abb5ff4cbdb84651ea4fb9b4c57e6e4062421d51f` |
| два | `Ru-два.ogg` | 0.940 s | `54c213c9ef9e385e9831a10f4a0f3d4abc2e811d441a804dc68655ab64192317` |
| три | `Ru-три.ogg` (transcoded mp3) | 0.864 s | `faa8e4fdd6f43b320a4822cef3154b4ecce56b932e090634573995a3403cd707` |
| четыре | `Ru-четыре.ogg` | 1.149 s | `77d6fdd5adacb488b49fdab9d00e0e4fda9207b8752c8c7d2bb46baf1e669542` |
| пять | `Ru-пять.ogg` | 1.200 s | `6a6ff3ec1e70148e4498b592d09a61cfdf4b88a380dc942cf4930f14669ab032` |

Word regions (seconds): [0–1.097], [1.497–2.437], [2.837–3.701],
[4.101–5.250], [5.650–6.850]. Silence gaps: [1.097–1.497], [2.437–2.837],
[3.701–4.101], [5.250–5.650]. The host test asserts no caption word overlaps
a gap — that is the proof VAD gating (not just the recognizer) is applied.

Attribution: the clips are the Russian-pronunciation `Ru-*.ogg` series on
Wikimedia Commons. The `два` and `три` clips are confirmed as The Shtooka
Project audio, CC-BY-2.0-FR. The `один`, `четыре`, and `пять` clips follow
the same series naming and were downloaded from the same Commons paths, but
their individual license/source pages were not verified — the Commons API
refused access during verification (2026-11-11). Their spoken content is
verified by the host test itself (the decode must contain all five words).
**Re-verify those three clips' licenses before publishing this repo.**

## silence.wav — 2.000 s, 16 kHz mono s16
SHA-256: `35babfbd1a756e6765981cf9ca2094ea3ecbb4cdca30dde34f68ccde6cb76c30`

Digital silence (ffmpeg `anullsrc`). Must decode to no words.

## noise.wav — 2.000 s, 16 kHz mono s16
SHA-256: `58db5ce8e890d50501359183d23e72956ee63aa9c4fc4b4055ab7085fbb9e54d`

Pink noise (ffmpeg `anoisesrc=color=pink`, amplitude 0.25). Must decode to
no words — VAD must reject it before the recognizer can hallucinate.
