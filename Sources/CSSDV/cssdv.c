// Vessel's entry point to fsphil's SSDV library (GPL-3).
#include "include/cssdv.h"
#include "ssdv.h"
#include <string.h>
#include <stdlib.h>

int cssdv_check(uint8_t *packet, cssdv_info *info) {
    int errors = 0;
    if (ssdv_dec_is_packet(packet, SSDV_PKT_SIZE, &errors) != 0) return 0;
    if (info) {
        ssdv_packet_info_t p;
        ssdv_dec_header(&p, packet);
        memset(info, 0, sizeof(*info));
        strncpy(info->callsign, p.callsign_s, sizeof(info->callsign) - 1);
        info->image_id = p.image_id;
        info->packet_id = p.packet_id;
        info->width = p.width;
        info->height = p.height;
        info->last = p.eoi;
    }
    return 1;
}

int cssdv_build(const uint8_t *packets, int count, uint8_t *out, int capacity) {
    if (count <= 0 || capacity <= 0) return 0;
    ssdv_t *s = malloc(sizeof(ssdv_t));
    if (!s) return 0;
    if (ssdv_dec_init(s, SSDV_PKT_SIZE) != SSDV_OK) { free(s); return 0; }
    ssdv_dec_set_buffer(s, out, (size_t)capacity);
    uint8_t pkt[SSDV_PKT_SIZE];
    for (int i = 0; i < count; ++i) {
        memcpy(pkt, packets + (size_t)i * SSDV_PKT_SIZE, SSDV_PKT_SIZE);
        ssdv_dec_feed(s, pkt);
    }
    uint8_t *jpeg = NULL;
    size_t length = 0;
    char rc = ssdv_dec_get_jpeg(s, &jpeg, &length);
    free(s);
    if (rc != SSDV_OK || jpeg != out || length > (size_t)capacity) return 0;
    return (int)length;
}

int cssdv_encode(const uint8_t *jpeg, int length, const char *callsign, int image_id, int quality, uint8_t *out, int capacity_packets) {
    ssdv_t *s = malloc(sizeof(ssdv_t));
    if (!s) return 0;
    char call[8];
    strncpy(call, callsign, 7); call[7] = 0;
    if (ssdv_enc_init(s, SSDV_TYPE_NORMAL, call, (uint8_t)image_id, (int8_t)quality, SSDV_PKT_SIZE) != SSDV_OK) { free(s); return 0; }
    uint8_t pkt[SSDV_PKT_SIZE];
    ssdv_enc_set_buffer(s, pkt);
    int made = 0, pos = 0;
    while (made < capacity_packets) {
        char c;
        while ((c = ssdv_enc_get_packet(s)) == SSDV_FEED_ME) {
            int n = length - pos < 128 ? length - pos : 128;
            if (n <= 0) { free(s); return made; }
            ssdv_enc_feed(s, (uint8_t *)jpeg + pos, (size_t)n);
            pos += n;
        }
        if (c == SSDV_EOI) break;
        if (c != SSDV_OK) { free(s); return 0; }
        memcpy(out + (size_t)made * SSDV_PKT_SIZE, pkt, SSDV_PKT_SIZE);
        made++;
    }
    free(s);
    return made;
}
