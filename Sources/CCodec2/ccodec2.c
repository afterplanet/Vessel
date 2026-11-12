// Vessel's entry point to David Rowe's Codec2 (LGPL-2.1), trimmed to the speech codec itself.
#include "include/ccodec2.h"
#include "codec2.h"

int ccodec2_decode_700c(const uint8_t *bytes, int frames, int16_t *out) {
    struct CODEC2 *c = codec2_create(CODEC2_MODE_700C);
    if (!c) return 0;
    int n = codec2_samples_per_frame(c);
    int bytes_per = (codec2_bits_per_frame(c) + 7) / 8;
    for (int i = 0; i < frames; ++i) {
        codec2_decode(c, out + (long)i * n, bytes + (long)i * bytes_per);
    }
    codec2_destroy(c);
    return frames * n;
}

int ccodec2_encode_700c(const int16_t *samples, int count, uint8_t *out) {
    struct CODEC2 *c = codec2_create(CODEC2_MODE_700C);
    if (!c) return 0;
    int n = codec2_samples_per_frame(c);
    int bytes_per = (codec2_bits_per_frame(c) + 7) / 8;
    int frames = count / n;
    for (int i = 0; i < frames; ++i) {
        codec2_encode(c, out + (long)i * bytes_per, (short *)(samples + (long)i * n));
    }
    codec2_destroy(c);
    return frames;
}
