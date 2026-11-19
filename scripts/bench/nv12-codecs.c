#include "nv12-codecs.h"
#include "../../Sources/CNV12Bitpack/include/CNV12Bitpack.h"

#include <lz4.h>
#include <string.h>
#include <zstd.h>

size_t nv12_encode_plane(NV12Method method, const uint8_t *source, uint8_t *destination,
                         size_t width, size_t height, int chroma, uint8_t *scratch) {
    size_t bytes = width * height;
    if (method == NV12Bitpack) {
        return fs_nv12_pack(source, width, destination, bytes, width, height, chroma);
    }
    if (method == NV12Zstd) {
        size_t result = ZSTD_compress(destination, bytes, source, bytes, -1);
        return ZSTD_isError(result) ? 0 : result;
    }
    if (method == NV12RowsLZ4) {
        memcpy(scratch, source, width);
        for (size_t i = width; i < bytes; ++i) scratch[i] = source[i] - source[i - width];
        source = scratch;
    }
    int result = LZ4_compress_default((const char *)source, (char *)destination, (int)bytes, (int)bytes);
    return result > 0 ? (size_t)result : 0;
}

int nv12_decode_plane(NV12Method method, const uint8_t *source, size_t encodedBytes,
                      uint8_t *destination, size_t width, size_t height, int chroma) {
    size_t bytes = width * height;
    if (method == NV12Bitpack) {
        return fs_nv12_unpack(source, encodedBytes, destination, width, width, height, chroma);
    }
    if (method == NV12Zstd) return ZSTD_decompress(destination, bytes, source, encodedBytes) == bytes;
    int size = LZ4_decompress_safe((const char *)source, (char *)destination, (int)encodedBytes, (int)bytes);
    if (size != (int)bytes) return 0;
    if (method == NV12RowsLZ4) {
        for (size_t y = 1; y < height; ++y) {
            uint8_t *row = destination + y * width;
            const uint8_t *above = row - width;
            for (size_t x = 0; x < width; ++x) row[x] += above[x];
        }
    }
    return 1;
}
