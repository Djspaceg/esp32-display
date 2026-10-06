// The board side of Doom's sound effects (doom/src/platform/
// doom_audio_bridge.h): the codec backend streaming uses, fed from a paced
// output task. Linked into Doom family images; reached only from a Doom boot.
#if defined(ESPDISP_DOOM_RUNTIME)

#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>

#include <board_config.h>
#include <platform/doom_audio_bridge.h>
#include <platform/doom_log.h>

#include "audio_backend.h"
#include "doom_audio_pace.h"

// Settled by display_stream before Doom is entered.
extern const board::Config *bcfg;

// Doom's sound effects (doom/src/platform/doom_sound_esp32.c.inc) on the
// codec the streaming audio engine uses. A Doom boot returns before that
// engine, its transport or the tone test could start, so the shared backend is
// Doom's alone; nothing here runs in a normal boot.
#if defined(ESPDISP_AUDIO_RUNTIME)
namespace {

// I2SClass's fixed transmit ring: 6 DMA buffers of 240 frames (ESP_I2S.cpp).
constexpr uint32_t DOOM_AUDIO_BUFFER_FRAMES = 240;
constexpr uint32_t DOOM_AUDIO_RING_FRAMES = 6 * DOOM_AUDIO_BUFFER_FRAMES;
// One whole DMA buffer per write (15 ms at 16 kHz). ESP-IDF 5.5's write drops
// a partly filled buffer when its free queue is nearly full, which is where
// the pacer runs, so a smaller block would leave holes of silence.
constexpr size_t DOOM_AUDIO_BLOCK_FRAMES = DOOM_AUDIO_BUFFER_FRAMES;
constexpr uint8_t DOOM_AUDIO_MAX_CHANNELS = 2;
// Queued right after a blocked write: the five buffers the free queue (one
// shorter than the ring) held back, plus the one the write just filled.
constexpr uint32_t DOOM_AUDIO_FULL_FRAMES = DOOM_AUDIO_RING_FRAMES;
// The pacer's floor before each render. A sound is heard 16 to 35 ms after
// the game starts it (test_doom_audio_pace.cpp), instead of about 90 ms;
// for about 90 ms in every 30 s, while the pacer re-measures, up to 100 ms.
constexpr uint32_t DOOM_AUDIO_LEAD_US = 16000;
constexpr uint32_t DOOM_AUDIO_PROBE_US = 30000000;
constexpr uint32_t DOOM_AUDIO_TASK_STACK = 4096;
// Core 0 is otherwise idle in a Doom boot (no WiFi, no UDP receive), and
// loopTask runs the engine on core 1. Priority 10 keeps the task ahead of
// anything else that does land on core 0.
constexpr UBaseType_t DOOM_AUDIO_TASK_PRIORITY = 10;
constexpr BaseType_t DOOM_AUDIO_TASK_CORE = 0;

SemaphoreHandle_t doomAudioMutex = nullptr;
doom_audio_render_fn doomAudioRender = nullptr;
int8_t doomAudioAmpPin = board::NO_PIN;
// The most audio that can be queued: a whole ring.
uint32_t doomAudioDrainMs = 0;

// One pass of the output task: sleep until the pacer's lead, render a block
// as late as that allows (so a sound the engine starts now is in this block
// or the next), write it. Returns the frames the codec took.
size_t doomAudioServiceOnce(doomaudio::OutputPacer &pacer, int16_t *block,
                            const audiobackend::Format &format) {
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  const TickType_t sleepTicks =
      pdMS_TO_TICKS(pacer.sleepUs(esp_timer_get_time()) / 1000U);
  if (sleepTicks > 0) vTaskDelay(sleepTicks);
  doomAudioRender(block, DOOM_AUDIO_BLOCK_FRAMES, format.channels);
  const int64_t before = esp_timer_get_time();
  const size_t written = backend.writeFrames(block, DOOM_AUDIO_BLOCK_FRAMES);
  pacer.wrote((uint32_t)written, before, esp_timer_get_time());
  // A failed write still lets the block's time pass, so voices end on
  // schedule and the engine frees their channels.
  if (written != DOOM_AUDIO_BLOCK_FRAMES) {
    const TickType_t blockTicks = pdMS_TO_TICKS(
        (DOOM_AUDIO_BLOCK_FRAMES * 1000U) / format.sampleRateHz);
    vTaskDelay(blockTicks > 0 ? blockTicks : 1);
  }
  return written;
}

void doomAudioTask(void *) {
  const audiobackend::Format format = audio::sharedCodecBackend().format();
  doomaudio::OutputPacer pacer(format.sampleRateHz, DOOM_AUDIO_FULL_FRAMES,
                               DOOM_AUDIO_LEAD_US, DOOM_AUDIO_PROBE_US);
  int16_t block[DOOM_AUDIO_BLOCK_FRAMES * DOOM_AUDIO_MAX_CHANNELS];
  while (true) doomAudioServiceOnce(pacer, block, format);
}

}  // namespace
#endif

extern "C" uint32_t doom_audio_begin(doom_audio_render_fn render) {
#if defined(ESPDISP_AUDIO_RUNTIME)
  if (render == nullptr || bcfg == nullptr || doomAudioRender != nullptr) {
    return 0;
  }
  const board::AudioConfig *audioConfig =
      board::generatedAudioConfig(bcfg->variant);
  if (audioConfig == nullptr ||
      audiobackend::classify(*audioConfig) ==
          audiobackend::DescriptorStatus::NoAudio) {
    return 0;
  }
  // Probes the codec and ADC chip IDs once, read-only, for a supported
  // descriptor; a 1.85C V1 stops here.
  const audiobackend::DescriptorStatus status = audio::boardAudioStatus(*bcfg);
  if (status != audiobackend::DescriptorStatus::Ready) {
    doom_log("sound: off, %s",
             status == audiobackend::DescriptorStatus::HardwareNotIdentified
                 ? "codec and ADC not identified"
                 : "unsupported audio descriptor");
    return 0;
  }
  const audiobackend::Format format =
      audiobackend::descriptorFormat(*audioConfig);
  if (format.channels == 0 || format.channels > DOOM_AUDIO_MAX_CHANNELS ||
      format.sampleRateHz == 0) {
    doom_log("sound: off, unsupported output format");
    return 0;
  }
  doomAudioMutex = xSemaphoreCreateMutex();
  if (doomAudioMutex == nullptr) {
    doom_log("sound: off, no memory for the mixer lock");
    return 0;
  }
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  // Same safe power-up as streaming, the amplifier last and off when any step
  // fails, but with no capture: Doom never reads the microphones, so the
  // ES7210 stays powered down and no receive DMA is allocated.
  if (!backend.startPlaybackOnly(*bcfg, *audioConfig, format)) {
    vSemaphoreDelete(doomAudioMutex);
    doomAudioMutex = nullptr;
    doom_log("sound: off, codec/I2S start failed; amp disabled");
    return 0;
  }
  doomAudioRender = render;
  if (xTaskCreatePinnedToCore(doomAudioTask, "doom_snd", DOOM_AUDIO_TASK_STACK,
                              nullptr, DOOM_AUDIO_TASK_PRIORITY, nullptr,
                              DOOM_AUDIO_TASK_CORE) != pdPASS) {
    backend.stop();
    doomAudioRender = nullptr;
    vSemaphoreDelete(doomAudioMutex);
    doomAudioMutex = nullptr;
    doom_log("sound: off, output task not created; amp disabled");
    return 0;
  }
  doomAudioAmpPin = audioConfig->pinAmpEnable;
  doomAudioDrainMs =
      (DOOM_AUDIO_RING_FRAMES * 1000U) / format.sampleRateHz + 1U;
  doom_log("sound: effects on, %lu Hz, %u channels, internal heap %u free",
           (unsigned long)format.sampleRateHz, (unsigned)format.channels,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
  return format.sampleRateHz;
#else
  (void)render;
  return 0;
#endif
}

extern "C" void doom_audio_lock(void) {
#if defined(ESPDISP_AUDIO_RUNTIME)
  if (doomAudioMutex != nullptr) xSemaphoreTake(doomAudioMutex, portMAX_DELAY);
#endif
}

extern "C" void doom_audio_unlock(void) {
#if defined(ESPDISP_AUDIO_RUNTIME)
  if (doomAudioMutex != nullptr) xSemaphoreGive(doomAudioMutex);
#endif
}

// Only the amplifier: it is the part that pops when I2S stops mid-sample at
// the restart, and a GPIO write cannot race the output task's I2S writes.
// The wait lets what is already queued reach the speaker first.
extern "C" void doom_audio_end(void) {
#if defined(ESPDISP_AUDIO_RUNTIME)
  if (doomAudioAmpPin == board::NO_PIN) return;
  delay(doomAudioDrainMs);
  digitalWrite(doomAudioAmpPin, LOW);
  doomAudioAmpPin = board::NO_PIN;
#endif
}

#if defined(ESPDISP_HOST_AUDIO_TEST) && defined(ESPDISP_AUDIO_RUNTIME)
// One pass of the output task with a fresh pacer.
size_t doomAudioServiceOnceForTest() {
  const audiobackend::Format format = audio::sharedCodecBackend().format();
  doomaudio::OutputPacer pacer(format.sampleRateHz, DOOM_AUDIO_FULL_FRAMES,
                               DOOM_AUDIO_LEAD_US, DOOM_AUDIO_PROBE_US);
  int16_t block[DOOM_AUDIO_BLOCK_FRAMES * DOOM_AUDIO_MAX_CHANNELS];
  return doomAudioServiceOnce(pacer, block, format);
}

void doomAudioResetForTest() {
  doomAudioMutex = nullptr;
  doomAudioRender = nullptr;
  doomAudioAmpPin = board::NO_PIN;
  doomAudioDrainMs = 0;
}
#endif

#endif  // ESPDISP_DOOM_RUNTIME
