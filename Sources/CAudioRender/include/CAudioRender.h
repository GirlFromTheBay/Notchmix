#ifndef CAUDIORENDER_H
#define CAUDIORENDER_H

#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// State shared between the control plane and one tap's real-time IOProc.
///
/// The control plane only touches it through the functions below; every
/// cross-thread field is a lock-free C11 atomic. The render path never
/// allocates, locks, logs, or calls into the Swift or Objective-C runtimes.
typedef struct nm_tap_state nm_tap_state;

/// Allocates the state for one tap session. Not real-time safe; call it from
/// the control plane before the IOProc is started.
///
/// @param initial_gain      Linear gain (0...1) the first callback renders at.
/// @param sample_rate       Device sample rate, used to size the gain ramp.
/// @param ramp_seconds      Length of the linear gain ramp (5-10 ms is typical).
/// @param tap_buffer_count  How many trailing input buffers belong to the tap.
///                          An aggregate lists hardware input streams first
///                          and tap streams last.
/// @param left_channel      Zero-based output channel that carries "left".
/// @param right_channel     Zero-based output channel that carries "right".
nm_tap_state *_Nullable nm_tap_state_create(float initial_gain,
                                            double sample_rate,
                                            double ramp_seconds,
                                            uint32_t tap_buffer_count,
                                            uint32_t left_channel,
                                            uint32_t right_channel);

/// Frees the state. Call only after the IOProc has been stopped and destroyed.
void nm_tap_state_destroy(nm_tap_state *_Nullable state);

/// Sets the gain the render path ramps toward. Wait-free; any thread.
void nm_tap_state_set_gain(nm_tap_state *_Nonnull state, float gain);

/// The gain most recently requested with nm_tap_state_set_gain.
float nm_tap_state_target_gain(const nm_tap_state *_Nonnull state);

/// Number of IOProc callbacks so far. Used as a liveness heartbeat.
uint64_t nm_tap_state_callbacks(const nm_tap_state *_Nonnull state);

/// Number of frames in which the tap delivered a non-zero sample, measured
/// before gain. Zero while the process is playing means the tap is not
/// receiving audio (typically a missing System Audio Recording permission).
uint64_t nm_tap_state_audible_frames(const nm_tap_state *_Nonnull state);

/// Renders one cycle: copies the tap's audio to the output with the ramped
/// gain applied. Real-time safe. Exposed separately from the IOProc so it can
/// be unit tested with hand-built buffer lists.
void nm_tap_render(nm_tap_state *_Nonnull state,
                   const AudioBufferList *_Nullable input,
                   AudioBufferList *_Nullable output);

/// AudioDeviceIOProc entry point. Pass a nm_tap_state as the client data.
OSStatus nm_tap_ioproc(AudioObjectID device,
                       const AudioTimeStamp *_Nonnull now,
                       const AudioBufferList *_Nonnull input,
                       const AudioTimeStamp *_Nonnull input_time,
                       AudioBufferList *_Nonnull output,
                       const AudioTimeStamp *_Nonnull output_time,
                       void *_Nullable client_data);

/// Declares that `proc` reads only the last `keep` of the device's `total`
/// input streams, so the HAL leaves the others switched off. Control plane
/// only; not real-time safe. Does nothing when there is nothing to switch off.
OSStatus nm_use_only_trailing_input_streams(AudioObjectID device,
                                            AudioDeviceIOProcID _Nonnull proc,
                                            uint32_t total,
                                            uint32_t keep);

#ifdef __cplusplus
}
#endif

#endif /* CAUDIORENDER_H */
