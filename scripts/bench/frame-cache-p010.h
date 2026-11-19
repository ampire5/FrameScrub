#include <stddef.h>
#include <stdint.h>

// The sample count is a multiple of four. Each group stores four upper bytes
// and one byte with the four remaining bit pairs.
void pack_p010(const uint16_t *source, uint8_t *destination, size_t samples);
void unpack_p010(const uint8_t *source, uint16_t *destination, size_t samples);
