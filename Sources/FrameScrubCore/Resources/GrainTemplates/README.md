# Prepared monochrome grain banks

Neutral patterns, not sample photographs. Each file has16 layers of64×64 little-endian
IEEE FP16 samples (131072bytes), zero mean and unit RMS before sampling/masking.
Only pipeline preparation reads these files; frame rendering samples immutable Metal textures.

- `av1.r16f`, SHA256 `47239db5d7c765a050e9bbd52b100a0df888e4be6be58e397c2a928ed7060fb9`.
  Luma-table synthesis adapted from Niklas Haas / libplacebo under the accompanying MIT
  permission in `AV1-LICENSE.txt`: Gaussian lookup,16-bit PRNG, lag1 integer AR,
  authored coefficients8/28/8/28 with shift7,8-bit table generation. Normalization and
  an offline edge blend follow extraction. Not a conformant full AV1/AFGS1 reconstruction.
- `particles.r16f`, SHA256 `25d1019d751959026bae1ad1cc6b5bfced47ca3aca0ff9144e2576730f878f0b`.
  Independently generated periodic Poisson Boolean-disc flat field: median radius.55px,
  log-spread.30,50% expected coverage,8× pixel-area integration,.25px optical blur.
  Inspired by stochastic grain models; not a port of IPOL code or full intensity-dependent
  physical image reconstruction.

Rebuild with `scripts/make-grain-banks.py --av1-source /path/to/film_grain_av1.c`
(NumPy required). Source: https://github.com/haasn/libplacebo/blob/master/src/shaders/film_grain_av1.c
The script validates source SHA256
`d0acee2090ad38777e12f2472bc3e970339b3aeb7eb20ac919cd12575dde3b69`.
Both banks reproduce the evaluated external experiment; application defaults remain off.

Physical-model reference: https://www.ipol.im/pub/art/2017/192/ .
