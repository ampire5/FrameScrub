#include "frame-cache-p010.h"

typedef enum {
    NV12LZ4,
    NV12Zstd,
    NV12RowsLZ4,
    NV12Bitpack,
} NV12Method;

// RowsLZ4 needs scratch of at least width * height bytes during encode.
// Bitpack uses the production row-aware codec.
// The payload is process-local and is restored only by the matching method.
size_t nv12_encode_plane(NV12Method method, const uint8_t *source, uint8_t *destination,
                         size_t width, size_t height, int chroma, uint8_t *scratch);
int nv12_decode_plane(NV12Method method, const uint8_t *source, size_t encodedBytes,
                      uint8_t *destination, size_t width, size_t height, int chroma);
