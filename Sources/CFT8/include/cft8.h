#ifndef CFT8_H
#define CFT8_H
#ifdef __cplusplus
extern "C" {
#endif
/// 1 if `text` packs into an FT8/FT4 message.
int cft8_valid(const char *text);
/// Samples needed for one transmission at `rate`.
int cft8_length(int is_ft4, int rate);
/// Renders GFSK audio at base tone `f0`. Returns the sample count, or 0 if `text` won't pack.
int cft8_render(const char *text, int is_ft4, float f0, int rate, float *out, int capacity);
/// Called once for each message found.
typedef void (*cft8_message_cb)(const char *text, float freq_hz, float time_sec, float snr, void *context);
/// Decodes one slot of audio, which should start at about the slot boundary. Returns how many messages were found.
int cft8_decode(const float *samples, int count, int rate, int is_ft4, float f_min, float f_max, cft8_message_cb cb, void *context);
#ifdef __cplusplus
}
#endif
#endif
