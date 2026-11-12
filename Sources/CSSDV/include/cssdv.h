#ifndef CSSDV_H
#define CSSDV_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define CSSDV_PACKET 256

typedef struct {
    char callsign[8];
    int image_id;
    int packet_id;
    int width;
    int height;
    int last;
} cssdv_info;

/// 1 if these 256 bytes are a valid SSDV packet. Errors that its own error correction can fix
/// are fixed in place.
int cssdv_check(uint8_t *packet, cssdv_info *info);
/// Rebuilds a JPEG from packets given in order. Missing ones leave grey blocks. Returns its length, or 0.
int cssdv_build(const uint8_t *packets, int count, uint8_t *out, int capacity);
/// Cuts a baseline JPEG into packets, for tests. Returns how many, or 0.
int cssdv_encode(const uint8_t *jpeg, int length, const char *callsign, int image_id, int quality, uint8_t *out, int capacity_packets);

#ifdef __cplusplus
}
#endif
#endif
