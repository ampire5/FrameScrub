# Artifact-confidence and bounded seam-correction experiment

2026-11-07, M4 Max,36GB, macOS27.2. External throwaway Swift/Metal experiment;
no app integration. Follows [the detailed 4K tests](algorithmic-deblock-4k.md).

## Candidate

Two passes, immutable source: dense RG16F horizontal/vertical seam confidence, then
gather-based correction. Unlike the first boundary8 prototype, no assumed grid origin.

For every potential seam, inspect the signed luma jump against the stronger adjacent
within-region gradient. Require coherent jump signs over five transverse samples and
another discontinuity at ±8/16/32 pixels. Reject large jumps and textured neighborhoods.
The confidence is an uncalibrated heuristic, not a learned probability of blocking.

Spread each selected discontinuity over four samples, weights +1/4,+1/2,−1/2,−1/4.
Accumulate horizontal/vertical corrections from the original, then clamp their sum.
Add the same scalar to RGB: luma-only correction before gamut clipping/quantization.

Profiles:

- Soft strict: jump-excess smoothstep1.5…5 RGB8 codes; coherence.65….95;
  repeated-excess1.5…4; amount.5, maximum correction2 codes.
- Strong strict: same confidence; amount1, maximum4 codes.
- Sensitive: jump-excess.5…2; coherence.35….75; repeated-excess.5…2;
  amount1, maximum4 codes.

Shared gates: jump rejection smoothstep12…24; mean adjacent-gradient rejection2…6.
Jump excess is `max(0, abs(jump) − 2 × adjacentGradient)`. All thresholds are exploratory,
not optimal product constants. There is no temporal history, diagonal-direction search,
learned semantic evidence, low-frequency reconstruction or actual sparse dispatch.

## Material and measurements

Reuse exactly the previous seven cases: native3840×2160 SVT town/park at50fps,
clean/H.264QP34/QP42,16frames each; public Apple FRC H.264QP34 at30fps,90frames.
Three profiles give558 sequential full4K operations. One command buffer in flight;
two codec threads. Source provenance and SVT companion document remain with the prior lab.

First three frames excluded from GPU samples:13 samples per SVT case,87 per Apple profile.
Saved full4K source/output/mask overlays at first/middle/last frames; exact two512×512 ROI
sequences in NPZ. Preview MP4s have labels, CRF12 and explicit4× repetition of0.32s SVT
excerpts; Apple preview is3seconds. No metrics use lossy previews.

| Workload | Strict soft median/P95 | Strict strong median/P95 | Sensitive median/P95 |
|---|---:|---:|---:|
| Apple4K90frames | 3.98/4.18 ms | 4.00/4.25 ms | 5.04/7.70 ms |
| TownQP34 | 4.76/5.16 ms | 4.64/5.07 ms | 5.56/8.04 ms |
| ParkQP34 | 3.81/4.19 ms | 3.80/3.94 ms | 5.72/7.54 ms |

Across cases, strict medians span3.39…6.44ms; sensitive3.33…6.07ms, P95 up to8.93ms.
Small short-case samples and run-to-run scheduling variation preclude fine rankings.
GPU execution excludes CPU texture transfer/readback, decoding and presentation. The
recorded transfer+compute wall metric includes replace/submit/wait/readback only.
Four shared textures allocate133,693,440bytes; this is not process/driver peak memory.
Full-resolution confidence is computed even when no output pixel changes. A mask alone
does not make this ROI processing or provide proportional compute savings.

## Results

**The tested candidate is not worth integrating on this evidence.**

- Strict confidence preserves detail but barely affects real artifacts. Across saved native
  frames, changed-pixel fraction averages0.28% soft/0.48% strong (equal-weight frame mean).
- Sensitive confidence changes3.55% on average, up to7.72% on a saved frame. Visible
  improvement remains small; broad block patches persist. This is intervention area,
  not detector accuracy or artifact-removal percentage.
- On the four compressed SVT cases, sensitive PSNR gain against pre-encode ROIs is only
  about0.001…0.008dB. Strict is smaller. These negligible values do not show useful
  restoration; inspected native crops likewise show little advantage.
- Clean ParkJoy ROI gradient energy is retained at99.7% by strong strict and98.5% by
  sensitive, versus90.2% by the previous protected adaptive profile. Much better retention
  here accompanies very weak cleanup. This diagnostic mixes grain and texture.
- Synthetic block steps are detected and softened; ramps and an isolated40-code edge are
  unchanged. But genuine repeated8-code bars also trigger confidently: about47% of their
  pixels change under strict profiles. Periodicity/coherence cannot distinguish such a
  legitimate pattern from identically shaped compression steps by themselves.
- The three-second sequence and correction-delta metrics do not validate perceptual
  flicker stability. No temporal stabilization was implemented or claimed.

The result exposes two separate issues: thresholds that protect detail miss weak/irregular
compression artifacts; relaxing them adds cost and false detections. Also, spreading a seam
over four pixels leaves block-interior offsets and larger patchiness essentially unresolved.
Faster hardware or a higher correction cap does not address either ambiguity.

## Implications

Keep this as a negative baseline, rather than another app toggle. The earlier protected
adaptive profile still has the clearer cosmetic effect on smooth regions, with its known
texture tradeoff. Avoid repeated threshold adjustments on this seam detector without a
new source of evidence or a different restoration operation.

A further research choice would be either coarse low-frequency correction under a better
mask, or a small context-aware learned detector; both need explicit clean negative examples
and real decoded compression artifacts. Encoder partition/QP evidence could improve
confidence only where actually available. These are hypotheses, not demonstrated solutions.
There is no evidence here to justify a broad promise of effective detail-preserving4K deblocking.

## Verification and artifacts

- Native Swift compiled; all558 sequence frames completed GPU work successfully.
- 63 saved full4K outputs match the previous decoded source RGB exactly at input and obey
  correction caps2/4 codes.
- Independent NumPy reference on five synthetic cases (including colored blocks), all
  three profiles: output maximum discrepancy1 RGB8 code; confidence maximum discrepancy
  at most0.00048828125. The strict formulas were retested after adding sensitive mode.
- Synthetic translation right3/down5, interior margin40: all three profiles exactly
  translation-equivalent, max discrepancy0. This is not a test of rescaling invariance.

The external research workspace contains both shader
revisions, runner/orchestration sources, raw timings, metrics, source/output/mask PNGs,
previews and parity/translation fixtures. Product tests were not rerun for this standalone
experiment and bench-document-only change. No runtime shader, model or dependency added.
