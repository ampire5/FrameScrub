# Subject Focus with RobustVideoMatting (optional, spike)

Subject Focus makes its masks with Vision by default. With the RobustVideoMatting models (RVM, Peter Lin et al., GPL-3.0
like this app) it uses RVM's alpha matte instead: a recurrent network that remembers the frames before, so the edge holds
still where Vision's per-frame masks flicker, and hair comes out whole. The models are not part of the app or the
repository: whoever wants them prepares them once with the script below. Without them nothing changes (View › Subject
Focus › Mask: RVM stays greyed).

## Preparing the models

```
brew install uv          # once
scripts/rvm/prepare-models.sh
```

The script fetches RVM's source at a pinned commit and its MobileNetV3 weights (checked against their SHA-256), exports four
Core ML models in a throwaway Python environment (PyTorch, coremltools; ~3 GB in a temp folder, deleted at the end) and
puts them in `~/Library/Application Support/RobustVideoMatting/`:

| Model | Used for |
|---|---|
| `rvm_mnv3_512x288.mlpackage`, `rvm_mnv3_288x512.mlpackage` | playback, landscape / portrait |
| `rvm_mnv3_768x432.mlpackage`, `rvm_mnv3_432x768.mlpackage` | a still frame (pause), 4 passes over it |

The app compiles each package the first time it is used (up to ~1 s, off the main thread) and keeps the compiled model
in `~/Library/Caches/FrameScrub/RVM`. `FRAMESCRUB_RVM_DIR` points to another folder (benches). Loupe reads the same
folder.

The export (`scripts/rvm/export.py`) differs from the models RVM publishes: alpha only (no foreground colour), an ML
Program in fp16 with fp16 recurrent state, the frame passed in already small, no refiner. That puts the whole network on
the neural engine (263 of 265 operations) and leaves the GPU to the picture; the published 1080p model splits between the
neural engine and the GPU and takes 20 ms a frame. The edge is refined in the app instead (below).

## How it works

- Playback: each frame scaled to 512×288 (288×512 for portrait video; other shapes stretched to the nearer one), one
  pass, the recurrent state carried from frame to frame. A seek, a jump of more than 4 frames or a cut starts it over
  (a cut: the frame's luma on a 32×18 grid changed by more than 20/255 on average; walking, zooms and pans reach 12, hard
  cuts 28–61; the state settles again within ~1 s, and starts close: 1–1.6/255 from the settled alpha).
- Scrubbing (paused, the wheel or a step brings a frame): the 768×432 model, its state carried from step to step (a
  step of up to 4 frames, either way), 2 passes after a jump or the switch from playback.
- A still frame (after 250 ms on pause): 768×432, 4 passes from a fresh state of its own (the scrubbing's state goes on
  after it).
- The edge: a fast guided filter (He & Sun 2015) in Core Image. On the matte's grid every 5×5 window fits the matte as
  a·luma + b of the picture; a and b, smoothed and scaled up, are applied to the full frame's luma, so the edge follows
  the picture's own edges at the frame's resolution. No erosion or feathering as for Vision's masks.
- View › Subject Focus › Mask: RVM / Mask: Vision switches live, for every window. RVM is the default when the models are
  there; `FRAMESCRUB_FOCUS_QUALITY=fast|balanced|accurate` starts with Vision; `FRAMESCRUB_FOCUS_REFINE=0`
  shows the matte only scaled up (benches).

## The panel

⌥H (`toggle-subject-focus-panel`, View › Subject Focus › Subject Focus Panel) shows Subject Focus's panel over the
video's right side, made after the mockup "Subject Focus panel": on/off (H) and the style for its window (⇧H steps
through them, Custom last); the background's brightness, blur and colour; the edge's softness, shrink or grow (points of
a 1080-line frame), falloff near the people, the people's contrast and the clean edge colour; and, for every window, the
mask (RVM or Vision, Vision's quality while playing and its steadiness, the sharper mask when paused), who (all or the
main people) and the mask tinted over the people. A slider makes the style Custom, starting from the style on screen.
Everything is kept in `UserDefaults` (`SubjectFocus.*`), not in framescrub.conf, while this is a spike; Reset to
Defaults puts it back.

It is an overlay card apart from the slots (they may all hold plugins), with the slots' card, backdrops (the ◐ button,
glass by default) and motion; it goes 150 ms after the pointer left it (past the window's right edge by up to 200 pt
still counts as in), with ⌥H, ✕ or a click on the video. Built the first time it shows, kept after.

The mockup's "Applies to: this folder / everywhere" and Save as Default are left out (one set for everything, kept as
it changes); "Largest person" and "Person under pointer" too (All / Main people is what the masks can do now).

Main thread's CPU time (`CLOCK_THREAD_CPUTIME_ID`, `FRAMESCRUB_FOCUS_PANEL=bench`, 5 rounds, M4 Max): the first show
15.5 ms (building it), then 0.3–1.1 ms; a slider step 0.14–0.25 ms (max 0.65); hiding 0.03 ms; no round slower than
the one before. Layout and drawing after the action are not in these numbers.

## Measurements

M4 Max, macOS 26, 2026-10-27, the machine busy with other work (idle ~15 % CPU).

Flicker, measured outside the app (`rvmbench`, scratchpad): the mask's change between frames after moving the previous
mask along the optical flow, only where the picture itself matched (of 255), and the share of the frame that jumps by
more than a quarter (‰).

| Mask | Time a frame | Runway 1080p (60 s): flicker / jumps ‰ | Talking head 720p webcam (30 s) |
|---|---|---|---|
| Vision balanced, raw | ~10 ms | 2.51 / 12.5 | 0.10 / 0.24 |
| Vision balanced + the luma smoothing (before) | ~10 ms | 1.36 / 6.5 | 0.08 / 0.21 |
| RVM, the published 1080p model | 20 ms | 1.15 / 4.4 | 0.50 / 1.8 (its refiner shimmers on the hair) |
| **RVM MobileNetV3 512×288 (this)** | **3.5 ms** | **0.80 / 3.0** | 0.10 / 0.00 |
| RVM MobileNetV3 768×432 | 7 ms | 0.76 / 2.8 | 0.09 / 0.01 |
| RVM ResNet50 512×288 | 7 ms | 0.83 / 2.9 | 0.10 / 0.00 |
| RVM ResNet50 768×432 | 15–18 ms | 0.87 / 2.9 | 0.09 / 0.00 |

ResNet50 is no steadier and 2–5× slower: MobileNetV3 is the one.

In the app (`FRAMESCRUB_FOCUS_LOG=1`, White, 18 s runs):

| Clip | Mask | fps | Mask ready | Mask after the frame | Draw CPU / GPU a frame | App CPU |
|---|---|---|---|---|---|---|
| Runway 1080p 24 fps | Vision balanced | 24 | 18 ms | 19 ms | 1.1 / 2.3 ms | 34 % |
| | RVM | 24 | 6.5 ms | 10 ms | 3.6 / 3.3 ms | 30 % |
| Runway 4K 24 fps | Vision balanced | 24 | 18 ms | 21 ms | 3.1 / 5.1 ms | 35 % |
| | RVM | 24 | 5.5 ms | 11 ms | 5.6 / 5.6 ms | 27 % |
| Runway 9:16 608×1080 | RVM | 24 | 7.9 ms | 11 ms | 3.3 / 1.5 ms | 32 % |

Every frame was drawn with its own mask in all runs. The draw times in this table are wall clock (the bench line measured
so then): the main thread's own CPU time (`CLOCK_THREAD_CPUTIME_ID`, measured since) is the same for both, 1080p: Vision
3.1–3.3 ms, RVM 3.1–3.4 ms without the edge refinement and 3.3–3.4 ms with it (~0.1–0.2 ms for the guided filter). The still frame's 4 passes: 41–63 ms (the first use of the
768 model on a machine also compiles it: ~0.8 s once).

Scrubbing: the error against the pause's mask (768×432, 6 passes; of 255) and the share off by more than a quarter,
measured outside the app (`rvmscrub`, scratchpad), runway 1080p:

| Scrub | Before: 512×288, state over ≤ 4 frames, 1 pass after a jump | Now: 768×432, 2 passes after a jump | 3 passes after a jump |
|---|---|---|---|
| ±1 frame a step | 0.70 / 2.2 ‰, 4.3 ms | **0.32 / 0.9 ‰, 6.7 ms** | 0.32 / 0.9 ‰ |
| 2 frames a step | 2.53 / 11.2 ‰ | **2.10 / 9.6 ‰** | 2.09 / 9.6 ‰ |
| fast, 8 frames a step | 1.49 / 5.7 ‰ | **0.57 / 1.6 ‰, 12 ms** | 0.35 / 0.9 ‰, 18 ms |
| fast, 16 frames a step | 1.35 / 5.2 ‰ | **0.55 / 1.9 ‰** | 0.36 / 1.1 ‰ |

Carrying the state over a jump instead of starting it over: 0.96 at 8 frames a step. 3 passes come close to the 20 ms a
frame waits for its mask, so 2. In the app (`FRAMESCRUB_FOCUS_SCRUB=<frames>,<steps a second>`, 20 s, machine load 5–12):
1 frame × 30/s 8.8 ms a mask, 13 ms after the frame; 1 × 60/s 8 ms, 16 ms; 8 × 30/s 14–15 ms, 23–26 ms; every frame was
drawn with its own mask.

What it looks like: the audience at the runway's edge is no longer in the mask (Vision includes it); hair is whole; a
model far down the runway can come out half transparent, and once in a while a small false blob shows for a frame or two.

## Open

- One model with enumerated sizes instead of four files (the weights are the same).
- Subject: Main People (View › Subject Focus; `FRAMESCRUB_FOCUS_MAIN=1`), `SubjectSelection`: the mask's connected
  regions (≥ 128) on its own grid, kept when at least 25 % of the largest one, or 12 % when kept the frame before (no
  blinking at the line); the rest cleared outside the kept regions grown by 6 px. ~1 ms a 512×288 mask, no extra model.
  Vision's person-instance masks separate people too (17 ms a 1080p frame, runway: the two models, the audience's heads
  and a far model each apart), but every frame is too dear and fewer lag behind the motion. Thresholds to be agreed.
