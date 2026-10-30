#include <stddef.h>
#include <stdint.h>
// Benchmark-only adapters. Owned output is freed with bench_free; no production dependency is introduced.
int bench_encode(int codec, const uint8_t *rgba, int w, int h, double quality, int effort, uint8_t **out, size_t *size);
int bench_decode(int codec, const uint8_t *data, size_t size, uint8_t **rgba, int *w, int *h);
void bench_free(void *p);
