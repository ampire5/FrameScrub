#include "frame-cache-p010.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#include <string.h>
#endif

void pack_p010(const uint16_t *source, uint8_t *destination, size_t samples) {
    for (size_t i = 0; i < samples; i += 4, source += 4, destination += 5) {
        destination[0] = source[0] >> 8;
        destination[1] = source[1] >> 8;
        destination[2] = source[2] >> 8;
        destination[3] = source[3] >> 8;
        destination[4] = ((source[0] >> 6) & 3)
                       | ((source[1] >> 4) & 12)
                       | ((source[2] >> 2) & 48)
                       | (source[3] & 192);
    }
}

void unpack_p010(const uint8_t *source, uint16_t *destination, size_t samples) {
#if defined(__aarch64__)
    // Four packed groups span 20 bytes. Gather upper bytes and replicate each
    // group's low-bit byte, then interleave the two bytes of each P010 sample.
    const uint8x16_t high_index = {0, 1, 2, 3, 5, 6, 7, 8, 10, 11, 12, 13, 15, 16, 17, 18};
    const uint8x16_t low_index = {4, 4, 4, 4, 9, 9, 9, 9, 14, 14, 14, 14, 19, 19, 19, 19};
    const int8x16_t low_shift = {6, 4, 2, 0, 6, 4, 2, 0, 6, 4, 2, 0, 6, 4, 2, 0};
    const uint8x16_t low_mask = vdupq_n_u8(0xC0);
    for (; samples >= 16; samples -= 16, source += 20, destination += 16) {
        uint32_t tail;
        memcpy(&tail, source + 16, sizeof(tail));
        uint8x16x2_t packed = {{
            vld1q_u8(source),
            vreinterpretq_u8_u32(vsetq_lane_u32(tail, vdupq_n_u32(0), 0)),
        }};
        uint8x16_t high = vqtbl2q_u8(packed, high_index);
        uint8x16_t low = vandq_u8(vshlq_u8(vqtbl2q_u8(packed, low_index), low_shift), low_mask);
        vst1q_u8((uint8_t *)destination, vzip1q_u8(low, high));
        vst1q_u8((uint8_t *)(destination + 8), vzip2q_u8(low, high));
    }
#endif
    for (size_t i = 0; i < samples; i += 4, source += 5, destination += 4) {
        unsigned low = source[4];
        destination[0] = (source[0] << 8) | ((low & 3) << 6);
        destination[1] = (source[1] << 8) | ((low & 12) << 4);
        destination[2] = (source[2] << 8) | ((low & 48) << 2);
        destination[3] = (source[3] << 8) | (low & 192);
    }
}
