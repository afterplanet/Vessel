#ifndef CCODEC2_H
#define CCODEC2_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/// Codec2 700C: 40 ms of 8 kHz speech in 28 bits, stored as 4 bytes with the last 4 bits unused.
#define CCODEC2_700C_SAMPLES 320
#define CCODEC2_700C_BYTES 4

/// Decodes `frames` 700C frames of 4 bytes each into 16-bit samples at 8 kHz.
/// `out` must hold frames * 320 samples. Returns how many samples were written.
int ccodec2_decode_700c(const uint8_t *bytes, int frames, int16_t *out);

/// Encodes 8 kHz speech into 700C frames, for tests. `samples` is rounded down to whole
/// frames, and `out` must hold 4 bytes for each. Returns how many frames were written.
int ccodec2_encode_700c(const int16_t *samples, int count, uint8_t *out);

#ifdef __cplusplus
}
#endif
#endif
