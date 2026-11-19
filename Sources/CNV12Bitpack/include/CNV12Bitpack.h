#ifndef CNV12Bitpack_h
#define CNV12Bitpack_h

#include <stddef.h>
#include <stdint.h>

// A Y or interleaved UV plane. A return value of zero signals insufficient output space.
size_t fs_nv12_pack(const uint8_t *source, size_t stride, uint8_t *output, size_t capacity,
                    size_t widthBytes, size_t rows, int chroma);
int fs_nv12_unpack(const uint8_t *source, size_t length, uint8_t *output, size_t stride,
                   size_t widthBytes, size_t rows, int chroma);

#endif
