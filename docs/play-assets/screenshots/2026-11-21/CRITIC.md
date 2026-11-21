# StoryCam Play screenshot cards — critic verdict, 2026-11-21

Bundle: 10 cards, 1080×1920, EN + RU (5 each), in this folder.
Source shots: real emulator captures from the 0.5.17 UI
(`~/workspace/storycam/screenshots-fresh/emulator-play-screenshots/`),
status bar cropped. Generator: `~/workspace/storycam/play-cards/build_cards.py`
(PIL compositing — the same method as the shipped feature graphic; the
app-store-screenshots Next.js editor was not used because it needs a live
browser session, which this run did not have).

Order (first-3 rule, hook-first, matches `docs/play-listing.md`):
1. Dual recording — "You and the scene, one take." (04-recording)
2. Live map — "Your route, right on screen." (06-last-video-menu)
3. Captions — "Captions that keep up." (02-captions-sheet)
4. Filters — "Make it look like a movie." (03-filters)
5. Share — "Shot. Shared. Done." (07-share-sheet)

Checks run this run (all 10 cards read back at full size + 160 px thumbnail test):

## Check 1 — KPI alignment (downloads): PASS
Slot 1 carries the primary value prop, slots 2–3 the differentiators,
all benefit copy, no feature labels. The first three cards show the
install reason in under a second at thumbnail size.

## Check 2 — product description alignment: FAIL (go-live blocker)
Everything shown exists in v0.5.17 (dual recording, map circle, captions
sheet with Auto/Русский/English, filter slider, share sheet) and every
shot is a real capture of the app running — nothing is mocked up.
BUT the camera preview in slots 1, 2 and 4 is the emulator's synthetic
test-pattern feed (flat green/brown blocks). A store visitor reads those
blocks as "the video" and the app as broken or fake. The cards are honest
about the UI and dishonest-looking about the footage.
- Slots 1, 2, 4: FAIL — preview-led, needs a real-phone re-shoot.
- Slots 3, 5: PASS — UI-led (settings sheet / share sheet); the preview
  is incidental and dimmed behind the sheet. These two could ship now.

## Check 3 — brand / style alignment: PASS
Deep navy #111747 + sunset coral #FF8A5C, same icon, same tagline family
("Film front & back at once."), bold dark style, Noto Sans — all taken
from the shipped feature graphic (`growth/brand.md`). One emphasis word
per headline, except slot 4 where the whole second line ("like a movie.")
is coral — accepted, it reads as one emphasis phrase.

## Verdict: FAIL — do not upload to the live listing yet
Design, copy, sizing (1080×1920, promotion-eligible) and brand all pass.
The fix is a re-shoot, not a redesign: slots 1, 2, 4 need the same shots
taken on a real phone (Den's phone — the only real-camera source), then
re-run `build_cards.py` with the new sources and re-run the critic.
Until then the bundle is a DRAFT. Nothing here was uploaded to Play
Console and the live listing is unchanged.

## What was fixed during this run
- First build clipped the "StoryCam" app-bar title inside the phone
  frame (status-bar crop cut 48 px, the title starts at ~30 px).
  Fixed: crop 28 px, rebuilt, verified by readback.
