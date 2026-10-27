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
- A still frame (after 250 ms on pause): 768×432, 4 passes from a fresh state.
- The edge: a fast guided filter (He & Sun 2015) in Core Image. On the matte's grid every 5×5 window fits the matte as
  a·luma + b of the picture; a and b, smoothed and scaled up, are applied to the full frame's luma, so the edge follows
  the picture's own edges at the frame's resolution. No erosion or feathering as for Vision's masks.
- View › Subject Focus › Mask: RVM / Mask: Vision switches live, for every window. RVM is the default when the models are
  there; `FRAMESCRUB_FOCUS_QUALITY=fast|balanced|accurate` starts with Vision; `FRAMESCRUB_FOCUS_REFINE=0`
  shows the matte only scaled up (benches).

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

What it looks like: the audience at the runway's edge is no longer in the mask (Vision includes it); hair is whole; a
model far down the runway can come out half transparent, and once in a while a small false blob shows for a frame or two.

## Open

- One model with enumerated sizes instead of four files (the weights are the same).
- "The main person only": RVM's matte times Vision's person-instance mask of the chosen person.
