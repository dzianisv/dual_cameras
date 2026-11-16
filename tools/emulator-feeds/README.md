# Emulator camera feeds (issue #79)

Two real video clips for distinct front/rear camera feeds — rear =
Big Buck Bunny, front = Sintel — reserved for the Track B
real-device proof. They were wired to the CI emulator via
`-camera-back/-camera-front videofile:` and loop-extended to 600 s,
but Stage 4 FAILED that route (PR #80 comment 6909005894): the CI
emulator's camera HAL reports no front+back concurrent combo for any
non-emulated feed, so the camera never opened. The Track A rework
runs CI on the emulated test-pattern feed instead and these fixtures
are currently UNREFERENCED by either workflow — they stay committed
as the record + Track B reuse, costing nothing at runtime. When a
real-device proof (or a different emulator image/HAL) uses them
again, the looped `front-feed.mp4` / `rear-feed.mp4` are generated
on the runner and gitignored; only the two trailers below are
committed.

## Sources (Blender Foundation open movies, CC-BY 3.0)

| Feed | Film | Source URL | Format | SHA-256 |
|---|---|---|---|---|
| rear | Big Buck Bunny (Project Peach, 2008) | https://download.blender.org/peach/trailer/trailer_720p.mov | h264 1280x720 25 fps + aac, 33.0 s, 17,810,888 B | `cb7be60feb4fd4ff5b006e35e824201a48361b7ebc2f2bbcaf3351912035561a` |
| front | Sintel (Project Durian, 2010) | https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4 | h264 1280x720 24 fps + aac, 52.2 s, 7,608,204 B | `cb0fe73fc0a7d543459996c0cdab730997e6eac1013d3ede18796f777cb7f273` |

License: Creative Commons Attribution 3.0 — both films are Blender
open movies, free to reuse and distribute with attribution
(Sintel: https://durian.blender.org/sharing/). Attribution:
© Blender Foundation — Big Buck Bunny (peach.blender.org) and Sintel
(durian.blender.org). Use here is CI test feeds only; no
redistribution beyond this repository.

## Why committed fixtures, not downloaded in-workflow

First tried download-in-workflow (cleaner repo). It failed in CI:
run 43804082643 — `curl: (22) The requested URL returned error: 403`
from download.blender.org to the GitHub runner's egress IP, while the
same URL returns 200 from a dev machine. Google's gtv-videos-bucket
samples 403 from cloud IPs too. Two media hosts blocking cloud egress
IPs makes a third host a gamble, not a fix — so the 25.4 MB of
trailers live here, with hashes above for provenance. The looped
600 s files stay generated (45 MB + 161 MB) and out of git.
