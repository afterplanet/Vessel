// Vessel's C entry point to ft8_lib. The two GFSK functions are from its demo/gen_ft8.c (MIT).
#include "include/cft8.h"
#include "ft8/encode.h"
#include "ft8/message.h"
#include "ft8/constants.h"
#include <math.h>
#include <stdlib.h>
#include <stdint.h>

#define FT8_SYMBOL_BT 2.0f
#define FT4_SYMBOL_BT 1.0f
#define GFSK_CONST_K 5.336446f

static void gfsk_pulse(int n_spsym, float symbol_bt, float* pulse)
{
    for (int i = 0; i < 3 * n_spsym; ++i)
    {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = GFSK_CONST_K * symbol_bt * (t + 0.5f);
        float arg2 = GFSK_CONST_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

/// Synthesize waveform data using GFSK phase shaping.
/// The output waveform will contain n_sym symbols.
/// @param[in] symbols Array of symbols (tones) (0-7 for FT8)
/// @param[in] n_sym Number of symbols in the symbol array
/// @param[in] f0 Audio frequency in Hertz for the symbol 0 (base frequency)
/// @param[in] symbol_bt Symbol smoothing filter bandwidth (2 for FT8, 1 for FT4)
/// @param[in] symbol_period Symbol period (duration), seconds
/// @param[in] signal_rate Sample rate of synthesized signal, Hertz
/// @param[out] signal Output array of signal waveform samples (should have space for n_sym*n_spsym samples)
///
static void synth_gfsk(const uint8_t* symbols, int n_sym, float f0, float symbol_bt, float symbol_period, int signal_rate, float* signal)
{
    int n_spsym = (int)(0.5f + signal_rate * symbol_period); // Samples per symbol
    int n_wave = n_sym * n_spsym;                            // Number of output samples
    float hmod = 1.0f;

    // Compute the smoothed frequency waveform.
    // Length = (nsym+2)*n_spsym samples, first and last symbols extended
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    float dphi[n_wave + 2 * n_spsym];

    // Shift frequency up by f0
    for (int i = 0; i < n_wave + 2 * n_spsym; ++i)
    {
        dphi[i] = 2 * M_PI * f0 / signal_rate;
    }

    float pulse[3 * n_spsym];
    gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < n_sym; ++i)
    {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
        {
            dphi[j + ib] += dphi_peak * symbols[i] * pulse[j];
        }
    }

    // Add dummy symbols at beginning and end with tone values equal to 1st and last symbol, respectively
    for (int j = 0; j < 2 * n_spsym; ++j)
    {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * symbols[0];
        dphi[j + n_sym * n_spsym] += dphi_peak * pulse[j] * symbols[n_sym - 1];
    }

    // Calculate and insert the audio waveform
    float phi = 0;
    for (int k = 0; k < n_wave; ++k)
    { // Don't include dummy symbols
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }

    // Apply envelope shaping to the first and last symbols
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i)
    {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }
}

// Callsigns that don't fit the standard format travel as a short hash. Like other FT8 programs,
// this remembers every callsign it has sent or heard in full, so a hash can be turned back into one.
#include <string.h>
#include <pthread.h>
#define CFT8_HASH_SLOTS 512
static struct { char call[12]; uint32_t n22; } cft8_calls[CFT8_HASH_SLOTS];
static int cft8_call_count = 0;
static pthread_mutex_t cft8_call_lock = PTHREAD_MUTEX_INITIALIZER;

static bool cft8_lookup(ftx_callsign_hash_type_t type, uint32_t hash, char *callsign) {
    int shift = (type == FTX_CALLSIGN_HASH_10_BITS) ? 12 : (type == FTX_CALLSIGN_HASH_12_BITS) ? 10 : 0;
    bool found = false;
    pthread_mutex_lock(&cft8_call_lock);
    for (int i = 0; i < cft8_call_count && i < CFT8_HASH_SLOTS; ++i) {
        if ((cft8_calls[i].n22 >> shift) == hash) { strcpy(callsign, cft8_calls[i].call); found = true; break; }
    }
    pthread_mutex_unlock(&cft8_call_lock);
    return found;
}

static void cft8_save(const char *callsign, uint32_t n22) {
    pthread_mutex_lock(&cft8_call_lock);
    int slot = -1;
    for (int i = 0; i < cft8_call_count && i < CFT8_HASH_SLOTS; ++i) {
        if (cft8_calls[i].n22 == n22) { slot = i; break; }
    }
    if (slot < 0) slot = (cft8_call_count++) % CFT8_HASH_SLOTS;
    if (cft8_call_count > 2 * CFT8_HASH_SLOTS) cft8_call_count = CFT8_HASH_SLOTS + cft8_call_count % CFT8_HASH_SLOTS;
    strncpy(cft8_calls[slot].call, callsign, 11);
    cft8_calls[slot].call[11] = 0;
    cft8_calls[slot].n22 = n22;
    pthread_mutex_unlock(&cft8_call_lock);
}

static ftx_callsign_hash_interface_t cft8_hash_if = { .lookup_hash = cft8_lookup, .save_hash = cft8_save };

int cft8_valid(const char *text) {
    ftx_message_t msg;
    return ftx_message_encode(&msg, &cft8_hash_if, text) == FTX_MESSAGE_RC_OK;
}

int cft8_length(int is_ft4, int rate) {
    int n = is_ft4 ? FT4_NN : FT8_NN;
    float period = is_ft4 ? FT4_SYMBOL_PERIOD : FT8_SYMBOL_PERIOD;
    return (int)(0.5f + n * period * rate);
}

int cft8_render(const char *text, int is_ft4, float f0, int rate, float *out, int capacity) {
    ftx_message_t msg;
    if (ftx_message_encode(&msg, &cft8_hash_if, text) != FTX_MESSAGE_RC_OK) return 0;
    int n = is_ft4 ? FT4_NN : FT8_NN;
    uint8_t tones[FT4_NN > FT8_NN ? FT4_NN : FT8_NN];
    if (is_ft4) ft4_encode(msg.payload, tones); else ft8_encode(msg.payload, tones);
    int need = cft8_length(is_ft4, rate);
    if (capacity < need) return 0;
    synth_gfsk(tones, n, f0, is_ft4 ? FT4_SYMBOL_BT : FT8_SYMBOL_BT,
               is_ft4 ? FT4_SYMBOL_PERIOD : FT8_SYMBOL_PERIOD, rate, out);
    return need;
}

// ---- Receiving. The search loop follows ft8_lib's demo/decode_ft8.c (MIT).
#include "ft8/decode.h"
#include "common/monitor.h"
#include <string.h>

#define CFT8_MAX_CANDIDATES 140
#define CFT8_MAX_DECODED 50

int cft8_decode(const float *samples, int count, int rate, int is_ft4, float f_min, float f_max, cft8_message_cb cb, void *context) {
    monitor_config_t cfg = { .f_min = f_min, .f_max = f_max, .sample_rate = rate, .time_osr = 2, .freq_osr = 2,
                             .protocol = is_ft4 ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8 };
    monitor_t mon;
    monitor_init(&mon, &cfg);
    for (int pos = 0; pos + mon.block_size <= count; pos += mon.block_size) {
        if (mon.wf.num_blocks >= mon.wf.max_blocks) break;
        monitor_process(&mon, samples + pos);
    }

    const ftx_waterfall_t *wf = &mon.wf;
    static _Thread_local ftx_candidate_t candidates[CFT8_MAX_CANDIDATES];
    int found = ftx_find_candidates(wf, CFT8_MAX_CANDIDATES, candidates, 10);

    ftx_message_t decoded[CFT8_MAX_DECODED];
    int num_decoded = 0;
    for (int i = 0; i < found && num_decoded < CFT8_MAX_DECODED; ++i) {
        const ftx_candidate_t *cand = &candidates[i];
        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(wf, cand, 25, &message, &status)) continue;
        int duplicate = 0;
        for (int k = 0; k < num_decoded; ++k) {
            if (decoded[k].hash == message.hash && memcmp(decoded[k].payload, message.payload, sizeof(message.payload)) == 0) { duplicate = 1; break; }
        }
        if (duplicate) continue;
        decoded[num_decoded++] = message;

        char text[FTX_MAX_MESSAGE_LENGTH];
        ftx_message_offsets_t offsets;
        if (ftx_message_decode(&message, &cft8_hash_if, text, &offsets) != FTX_MESSAGE_RC_OK) continue;
        float freq = (mon.min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / mon.symbol_period;
        float time = (cand->time_offset + (float)cand->time_sub / wf->time_osr) * mon.symbol_period;
        if (cb) cb(text, freq, time, cand->score * 0.5f, context);
    }
    monitor_free(&mon);
    return num_decoded;
}
