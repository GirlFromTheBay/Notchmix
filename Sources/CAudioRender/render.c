#include "CAudioRender.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// The render path relies on these being genuinely lock-free.
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "32-bit atomics must be lock-free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock-free");

/// Upper bound on channels handled per side. Anything beyond is left silent.
#define NM_MAX_CHANNELS 64
#define NM_NO_SOURCE UINT32_MAX

struct nm_tap_state {
    // Written by the control plane, read by the audio thread.
    _Atomic uint32_t target_gain_bits;

    // Written by the audio thread, read by the control plane.
    _Atomic uint64_t callbacks;
    _Atomic uint64_t audible_frames;

    // Audio thread only.
    float current_gain;
    float ramp_target;
    float ramp_step;
    uint32_t ramp_remaining;

    // Immutable after creation.
    uint32_t ramp_frames;
    uint32_t tap_buffer_count;
    uint32_t left_channel;
    uint32_t right_channel;
};

typedef struct {
    float *base;
    uint32_t stride;
} nm_channel;

static inline float nm_clamp_gain(float gain) {
    if (!isfinite(gain)) return 1.0f;
    if (gain < 0.0f) return 0.0f;
    if (gain > 1.0f) return 1.0f;
    return gain;
}

static inline uint32_t nm_float_bits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static inline float nm_bits_float(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

nm_tap_state *nm_tap_state_create(float initial_gain,
                                  double sample_rate,
                                  double ramp_seconds,
                                  uint32_t tap_buffer_count,
                                  uint32_t left_channel,
                                  uint32_t right_channel) {
    nm_tap_state *state = calloc(1, sizeof(nm_tap_state));
    if (!state) return NULL;

    float gain = nm_clamp_gain(initial_gain);
    atomic_init(&state->target_gain_bits, nm_float_bits(gain));
    atomic_init(&state->callbacks, 0);
    atomic_init(&state->audible_frames, 0);
    state->current_gain = gain;
    state->ramp_target = gain;
    state->ramp_step = 0.0f;
    state->ramp_remaining = 0;

    double frames = sample_rate * ramp_seconds;
    if (!(frames >= 1.0)) frames = 1.0;        // also catches NaN
    if (frames > 96000.0) frames = 96000.0;
    state->ramp_frames = (uint32_t)frames;
    state->tap_buffer_count = tap_buffer_count ? tap_buffer_count : 1;
    state->left_channel = left_channel;
    state->right_channel = right_channel;
    return state;
}

void nm_tap_state_destroy(nm_tap_state *state) {
    free(state);
}

void nm_tap_state_set_gain(nm_tap_state *state, float gain) {
    atomic_store_explicit(&state->target_gain_bits,
                          nm_float_bits(nm_clamp_gain(gain)),
                          memory_order_relaxed);
}

float nm_tap_state_target_gain(const nm_tap_state *state) {
    return nm_bits_float(atomic_load_explicit(&state->target_gain_bits, memory_order_relaxed));
}

uint64_t nm_tap_state_callbacks(const nm_tap_state *state) {
    return atomic_load_explicit(&state->callbacks, memory_order_relaxed);
}

uint64_t nm_tap_state_audible_frames(const nm_tap_state *state) {
    return atomic_load_explicit(&state->audible_frames, memory_order_relaxed);
}

/// Flattens buffers [first, count) into per-channel pointers and returns the
/// channel count. `frames` is lowered to the shortest buffer seen.
static uint32_t nm_collect_channels(const AudioBufferList *list,
                                    uint32_t first,
                                    nm_channel *channels,
                                    uint32_t *frames) {
    uint32_t count = 0;
    for (uint32_t b = first; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &list->mBuffers[b];
        uint32_t per_frame = buffer->mNumberChannels;
        // A NULL buffer is a stream the HAL was told this IOProc does not use.
        if (!buffer->mData || per_frame == 0) continue;
        uint32_t buffer_frames = buffer->mDataByteSize / (per_frame * (uint32_t)sizeof(float));
        if (buffer_frames < *frames) *frames = buffer_frames;
        for (uint32_t c = 0; c < per_frame && count < NM_MAX_CHANNELS; c++) {
            channels[count].base = (float *)buffer->mData + c;
            channels[count].stride = per_frame;
            count++;
        }
    }
    return count;
}

void nm_tap_render(nm_tap_state *state,
                   const AudioBufferList *input,
                   AudioBufferList *output) {
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    if (!output) return;

    // This aggregate owns the physical output, so start from silence. Any
    // early return below then plays nothing rather than stale memory.
    for (uint32_t b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (buffer->mData) memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    if (!input || input->mNumberBuffers == 0) return;

    nm_channel outs[NM_MAX_CHANNELS];
    nm_channel ins[NM_MAX_CHANNELS];
    uint32_t frames = UINT32_MAX;

    uint32_t out_count = nm_collect_channels(output, 0, outs, &frames);
    uint32_t first_tap_buffer = input->mNumberBuffers > state->tap_buffer_count
        ? input->mNumberBuffers - state->tap_buffer_count
        : 0;
    uint32_t in_count = nm_collect_channels(input, first_tap_buffer, ins, &frames);
    if (out_count == 0 || in_count == 0 || frames == 0 || frames == UINT32_MAX) return;

    // Decide which input channel feeds each output channel.
    uint32_t source[NM_MAX_CHANNELS];
    for (uint32_t c = 0; c < out_count; c++) source[c] = NM_NO_SOURCE;

    int fold_to_mono = 0;
    if (in_count == out_count) {
        for (uint32_t c = 0; c < out_count; c++) source[c] = c;
    } else if (out_count == 1) {
        fold_to_mono = in_count >= 2;
        source[0] = 0;
    } else if (in_count == 1) {
        uint32_t left = state->left_channel < out_count ? state->left_channel : 0;
        uint32_t right = state->right_channel < out_count ? state->right_channel : (out_count - 1);
        source[left] = 0;
        source[right] = 0;
    } else if (in_count == 2) {
        // Stereo mixdown tap onto a multichannel device.
        uint32_t left = state->left_channel < out_count ? state->left_channel : 0;
        uint32_t right = state->right_channel < out_count ? state->right_channel : 1;
        source[left] = 0;
        source[right] = 1;
    } else {
        uint32_t shared = in_count < out_count ? in_count : out_count;
        for (uint32_t c = 0; c < shared; c++) source[c] = c;
    }

    // Start a fresh linear ramp whenever the requested gain moved.
    float target = nm_bits_float(atomic_load_explicit(&state->target_gain_bits, memory_order_relaxed));
    if (target != state->ramp_target) {
        state->ramp_target = target;
        state->ramp_remaining = state->ramp_frames;
        state->ramp_step = (target - state->current_gain) / (float)state->ramp_frames;
    }

    // "Audible" is measured before gain so a muted app still counts as alive.
    uint32_t probe_count = in_count < 2 ? in_count : 2;
    uint64_t audible = 0;

    for (uint32_t f = 0; f < frames; f++) {
        if (state->ramp_remaining) {
            state->current_gain += state->ramp_step;
            if (--state->ramp_remaining == 0) state->current_gain = state->ramp_target;
        }
        float gain = state->current_gain;

        int heard = 0;
        for (uint32_t c = 0; c < probe_count; c++) {
            if (ins[c].base[(size_t)f * ins[c].stride] != 0.0f) heard = 1;
        }
        audible += (uint64_t)heard;

        if (fold_to_mono) {
            float left = ins[0].base[(size_t)f * ins[0].stride];
            float right = ins[1].base[(size_t)f * ins[1].stride];
            outs[0].base[(size_t)f * outs[0].stride] = 0.5f * (left + right) * gain;
            continue;
        }
        for (uint32_t c = 0; c < out_count; c++) {
            uint32_t s = source[c];
            if (s == NM_NO_SOURCE) continue;
            outs[c].base[(size_t)f * outs[c].stride] = ins[s].base[(size_t)f * ins[s].stride] * gain;
        }
    }

    if (audible) {
        atomic_fetch_add_explicit(&state->audible_frames, audible, memory_order_relaxed);
    }
}

OSStatus nm_tap_ioproc(AudioObjectID device,
                       const AudioTimeStamp *now,
                       const AudioBufferList *input,
                       const AudioTimeStamp *input_time,
                       AudioBufferList *output,
                       const AudioTimeStamp *output_time,
                       void *client_data) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    if (client_data) nm_tap_render((nm_tap_state *)client_data, input, output);
    return noErr;
}

OSStatus nm_use_only_trailing_input_streams(AudioObjectID device,
                                            AudioDeviceIOProcID proc,
                                            uint32_t total,
                                            uint32_t keep) {
    if (total == 0 || keep >= total) return noErr;

    // Core Audio's own variable-length struct: one on/off flag per stream.
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + (size_t)total * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudio_MemFullError;

    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = total;
    for (uint32_t stream = total - keep; stream < total; stream++) {
        usage->mStreamIsOn[stream] = 1;
    }

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
