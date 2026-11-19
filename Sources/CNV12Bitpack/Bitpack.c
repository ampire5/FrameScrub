#include "CNV12Bitpack.h"
#include <string.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// For 32 samples store a base and differences of 0, 2, 4 or 6 bits.
// Values spanning the full range use a tagged raw block. Each byte in the
// packed streams corresponds to an independent SIMD lane.
static size_t pack_block(const uint8_t *samples, uint8_t *output, size_t available) {
    uint8_t low = 255, high = 0;
#if defined(__aarch64__)
    uint8x16_t a = vld1q_u8(samples);
    uint8x16_t b = vld1q_u8(samples + 16);
    low = vminvq_u8(vminq_u8(a, b));
    high = vmaxvq_u8(vmaxq_u8(a, b));
#else
    for (size_t i = 0; i < 32; ++i) {
        if (samples[i] < low) low = samples[i];
        if (samples[i] > high) high = samples[i];
    }
#endif
    unsigned range = high - low;
    unsigned bits = range == 0 ? 0 : range < 4 ? 2 : range < 16 ? 4 : range < 64 ? 6 : 8;
    size_t size = bits == 8 ? 33 : 2 + 4 * bits;
    if (size > available) return 0;
    output[0] = (uint8_t)bits;
    if (bits == 8) {
        memcpy(output + 1, samples, 32);
        return size;
    }
    output[1] = low;
    if (bits == 0) return size;
    uint8_t *packed = output + 2;
#if defined(__aarch64__)
    uint8x16_t base = vdupq_n_u8(low);
    a = vsubq_u8(a, base);
    b = vsubq_u8(b, base);
    if (bits >= 4) {
        vst1q_u8(packed, vorrq_u8(vandq_u8(a, vdupq_n_u8(15)), vshlq_n_u8(b, 4)));
        if (bits == 4) return size;
        packed += 16;
        a = vshrq_n_u8(a, 4);
        b = vshrq_n_u8(b, 4);
    }
    uint8x8_t pairsA = vorr_u8(vget_low_u8(a), vshl_n_u8(vget_high_u8(a), 2));
    uint8x8_t pairsB = vorr_u8(vget_low_u8(b), vshl_n_u8(vget_high_u8(b), 2));
    vst1_u8(packed, vorr_u8(pairsA, vshl_n_u8(pairsB, 4)));
#else
    if (bits >= 4) {
        for (size_t i = 0; i < 16; ++i) {
            packed[i] = ((samples[i] - low) & 15) | ((samples[i + 16] - low) << 4);
        }
        if (bits == 4) return size;
        packed += 16;
    }
    unsigned shift = bits == 6 ? 4 : 0;
    for (size_t i = 0; i < 8; ++i) {
        packed[i] = ((samples[i] - low) >> shift) | (((samples[i + 8] - low) >> shift) << 2)
                    | (((samples[i + 16] - low) >> shift) << 4) | (((samples[i + 24] - low) >> shift) << 6);
    }
#endif
    return size;
}

static size_t unpack_block(const uint8_t *input, size_t available, uint8_t *samples) {
    if (available == 0) return 0;
    unsigned bits = input[0];
    if (bits > 8 || (bits & 1) != 0) return 0;
    size_t size = bits == 8 ? 33 : 2 + 4 * bits;
    if (size > available) return 0;
    if (bits == 8) {
        memcpy(samples, input + 1, 32);
        return size;
    }
    uint8_t low = input[1];
    if (bits == 0) {
        memset(samples, low, 32);
        return size;
    }
    const uint8_t *packed = input + 2;
#if defined(__aarch64__)
    uint8x16_t a = vdupq_n_u8(0);
    uint8x16_t b = vdupq_n_u8(0);
    if (bits >= 4) {
        uint8x16_t nibbles = vld1q_u8(packed);
        a = vandq_u8(nibbles, vdupq_n_u8(15));
        b = vshrq_n_u8(nibbles, 4);
        packed += 16;
    }
    if (bits != 4) {
        uint8x8_t pairs = vld1_u8(packed);
        uint8x8_t mask = vdup_n_u8(3);
        uint8x16_t upperA = vcombine_u8(vand_u8(pairs, mask), vand_u8(vshr_n_u8(pairs, 2), mask));
        uint8x16_t upperB = vcombine_u8(vand_u8(vshr_n_u8(pairs, 4), mask), vshr_n_u8(pairs, 6));
        if (bits == 6) {
            upperA = vshlq_n_u8(upperA, 4);
            upperB = vshlq_n_u8(upperB, 4);
        }
        a = vorrq_u8(a, upperA);
        b = vorrq_u8(b, upperB);
    }
    uint8x16_t base = vdupq_n_u8(low);
    vst1q_u8(samples, vaddq_u8(a, base));
    vst1q_u8(samples + 16, vaddq_u8(b, base));
#else
    for (size_t i = 0; i < 32; ++i) {
        unsigned value = 0;
        if (bits >= 4) value = (packed[i % 16] >> (4 * (i / 16))) & 15;
        if (bits != 4) {
            unsigned pairs = packed[(bits == 6 ? 16 : 0) + i % 8];
            value |= ((pairs >> (2 * (i / 8))) & 3) << (bits == 6 ? 4 : 0);
        }
        samples[i] = (uint8_t)(low + value);
    }
#endif
    return size;
}

// Contiguous complete groups per row allow NEON loads even on padded surfaces.
size_t fs_nv12_pack(const uint8_t *source, size_t stride, uint8_t *output, size_t capacity,
                    size_t widthBytes, size_t rows, int chroma) {
    size_t encoded = 0;
    size_t group = chroma ? 64 : 32;
    size_t whole = widthBytes - widthBytes % group;
    size_t tail = widthBytes - whole;
    for (size_t row = 0; row < rows; ++row, source += stride) {
        for (size_t i = 0; i < whole; i += group) {
            if (!chroma) {
                size_t count = pack_block(source + i, output + encoded, capacity - encoded);
                if (count == 0) return 0;
                encoded += count;
                continue;
            }
            uint8_t u[32], v[32];
#if defined(__aarch64__)
            uint8x16x2_t a = vld2q_u8(source + i);
            uint8x16x2_t b = vld2q_u8(source + i + 32);
            vst1q_u8(u, a.val[0]); vst1q_u8(u + 16, b.val[0]);
            vst1q_u8(v, a.val[1]); vst1q_u8(v + 16, b.val[1]);
#else
            for (size_t j = 0; j < 32; ++j) {
                u[j] = source[i + 2 * j];
                v[j] = source[i + 2 * j + 1];
            }
#endif
            size_t first = pack_block(u, output + encoded, capacity - encoded);
            if (first == 0) return 0;
            encoded += first;
            size_t second = pack_block(v, output + encoded, capacity - encoded);
            if (second == 0) return 0;
            encoded += second;
        }
        if (capacity - encoded < tail) return 0;
        memcpy(output + encoded, source + whole, tail);
        encoded += tail;
    }
    return encoded;
}

int fs_nv12_unpack(const uint8_t *source, size_t length, uint8_t *output, size_t stride,
                   size_t widthBytes, size_t rows, int chroma) {
    size_t offset = 0;
    size_t group = chroma ? 64 : 32;
    size_t whole = widthBytes - widthBytes % group;
    size_t tail = widthBytes - whole;
    for (size_t row = 0; row < rows; ++row, output += stride) {
        for (size_t i = 0; i < whole; i += group) {
            if (!chroma) {
                size_t count = unpack_block(source + offset, length - offset, output + i);
                if (count == 0) return 0;
                offset += count;
                continue;
            }
            uint8_t u[32], v[32];
            size_t first = unpack_block(source + offset, length - offset, u);
            if (first == 0) return 0;
            offset += first;
            size_t second = unpack_block(source + offset, length - offset, v);
            if (second == 0) return 0;
            offset += second;
#if defined(__aarch64__)
            uint8x16x2_t a = {{vld1q_u8(u), vld1q_u8(v)}};
            uint8x16x2_t b = {{vld1q_u8(u + 16), vld1q_u8(v + 16)}};
            vst2q_u8(output + i, a);
            vst2q_u8(output + i + 32, b);
#else
            for (size_t j = 0; j < 32; ++j) {
                output[i + 2 * j] = u[j];
                output[i + 2 * j + 1] = v[j];
            }
#endif
        }
        if (length - offset < tail) return 0;
        memcpy(output + whole, source + offset, tail);
        offset += tail;
    }
    return offset == length;
}
