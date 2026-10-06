// Host test for Doom's sound effects: the engine's sound dispatch
// (doom/src/i_sound.c.inc) and the board sound module behind it, compiled
// unmodified as C by doom_sound_unit.c against fakes/doom_sound.
//
// The board side is faked at the audio bridge display_stream provides: the
// test plays the codec's output task by calling the render function the
// module registers, so it hears exactly the samples the speaker would get.
//
// Properties:
// - A sound the engine starts reaches the output, for its whole length, at
//   the codec's rate, on every output channel, scaled by its volume.
// - Several sounds mix and clip instead of wrapping.
// - Stop, volume changes and replacement on a channel take effect at once.
// - Malformed or missing sound lumps, and out-of-range channels, play
//   nothing and touch no memory outside the lump.
// - A board without audio leaves sound off exactly as before.
// - Quitting lets the quit sound play out before the amplifier goes off.
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <strings.h>
#include <vector>

#include <esp_system.h>
#include <freertos/task.h>

extern "C" {
#include "doomtype.h"
#include "i_sound.h"
}

#include "platform/doom_audio_bridge.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

// ---- Engine and platform fakes ----------------------------------------------

extern "C" {
boolean screensaver_mode = false;
int M_CheckParm(char *) { return 0; }
void M_BindVariable(char *, void *) {}
void doom_log(const char *, ...) {}
void doom_log_stage(const char *) {}
void doom_fail_restart(const char *reason, bool) {
  printf("FAIL doom_fail_restart: %s\n", reason);
  exit(1);
}
void esp_restart(void) {
  printf("FAIL esp_restart\n");
  exit(1);
}
void vTaskDelay(TickType_t) {}
}

static void renderMs(int ms);
// The engine's sleep: the output task keeps playing meanwhile.
extern "C" void I_Sleep(int ms) { renderMs(ms); }

// The memory-mapped WAD: lump name -> lump bytes.
static std::vector<std::string> lumpNames;
static std::vector<std::vector<uint8_t>> lumpData;

extern "C" int W_CheckNumForName(char *name) {
  for (size_t i = 0; i < lumpNames.size(); ++i) {
    if (strncasecmp(lumpNames[i].c_str(), name, 8) == 0) return (int)i;
  }
  return -1;
}

extern "C" int W_LumpLength(unsigned int lump) {
  if (lump >= lumpData.size()) {
    printf("FAIL W_LumpLength(%u) out of range\n", lump);
    exit(1);
  }
  return (int)lumpData[lump].size();
}

extern "C" void *W_CacheLumpNum(int lump, int) {
  if (lump < 0 || (size_t)lump >= lumpData.size()) {
    printf("FAIL W_CacheLumpNum(%d) out of range\n", lump);
    exit(1);
  }
  return lumpData[(size_t)lump].data();
}

static int addLump(const std::string &name, const std::vector<uint8_t> &data) {
  lumpNames.push_back(name);
  lumpData.push_back(data);
  return (int)lumpNames.size() - 1;
}

// DMX format 3: u16 format, u16 rate, u32 length, then `length` unsigned
// 8-bit samples of which DMX skips 16 at each end. The pads here are 0x00,
// full negative, so a module that plays them is caught by its output.
static std::vector<uint8_t> dmx(uint16_t rate,
                                const std::vector<uint8_t> &samples) {
  const uint32_t length = (uint32_t)samples.size() + 32;
  std::vector<uint8_t> lump = {
      3, 0, (uint8_t)rate, (uint8_t)(rate >> 8),
      (uint8_t)length, (uint8_t)(length >> 8), (uint8_t)(length >> 16),
      (uint8_t)(length >> 24)};
  lump.insert(lump.end(), 16, 0x00);
  lump.insert(lump.end(), samples.begin(), samples.end());
  lump.insert(lump.end(), 16, 0x00);
  return lump;
}

// ---- Audio bridge fake ------------------------------------------------------

static uint32_t boardRate = 16000;  // 0: this board has no usable audio
static int beginCalls = 0;
static int endCalls = 0;
static int lockDepth = 0;
static int lockCalls = 0;
static bool lockMisuse = false;
static doom_audio_render_fn render = nullptr;

extern "C" uint32_t doom_audio_begin(doom_audio_render_fn fn) {
  beginCalls++;
  if (boardRate == 0) return 0;
  render = fn;
  return boardRate;
}

extern "C" void doom_audio_lock(void) {
  if (lockDepth != 0) lockMisuse = true;
  lockDepth++;
  lockCalls++;
}

extern "C" void doom_audio_unlock(void) {
  if (lockDepth != 1) lockMisuse = true;
  lockDepth--;
}

static size_t audibleBeforeEnd = 0;
static size_t audibleRendered = 0;

extern "C" void doom_audio_end(void) {
  endCalls++;
  audibleBeforeEnd = audibleRendered;
}

static void renderMs(int ms) {
  std::vector<int16_t> out((size_t)ms * boardRate / 1000 * 2);
  if (render != nullptr) render(out.data(), out.size() / 2, 2);
  for (size_t f = 0; f < out.size() / 2; ++f) {
    if (out[2 * f] != 0) audibleRendered++;
  }
}

// Whether `call` reached the voices only under the lock, as the output task
// reads them under it.
template <typename Call>
static bool underLock(Call call) {
  const int before = lockCalls;
  call();
  return lockCalls > before && lockDepth == 0 && !lockMisuse;
}

// What the codec would be sent for `frames` frames.
static std::vector<int16_t> pull(size_t frames, unsigned channels = 2) {
  std::vector<int16_t> out(frames * channels, 0x5555);
  if (render != nullptr) render(out.data(), frames, channels);
  return out;
}

static bool silent(const std::vector<int16_t> &samples) {
  for (int16_t s : samples) {
    if (s != 0) return false;
  }
  return true;
}

// Frames before the output goes quiet for good.
static size_t audibleFrames(const std::vector<int16_t> &samples,
                            unsigned channels = 2) {
  size_t last = 0;
  for (size_t i = 0; i < samples.size(); ++i) {
    if (samples[i] != 0) last = i / channels + 1;
  }
  return last;
}

static sfxinfo_t makeSfx(const char *name, sfxinfo_t *link = nullptr) {
  sfxinfo_t sfx = {};
  snprintf(sfx.name, sizeof(sfx.name), "%s", name);
  sfx.link = link;
  sfx.lumpnum = -1;
  return sfx;
}

// The engine looks a sound's lump up once, through the module, then starts it.
static int start(sfxinfo_t &sfx, int channel, int vol, int sep = 128) {
  if (sfx.lumpnum < 0) sfx.lumpnum = I_GetSfxLumpNum(&sfx);
  return I_StartSound(&sfx, channel, vol, sep);
}

int main() {
  // A full-scale constant tone, 100 ms at Doom's 11025 Hz.
  addLump("DSPISTOL", dmx(11025, std::vector<uint8_t>(1103, 0xFF)));
  // The same length of full-scale negative, to mix against the tone.
  addLump("DSSHOTGN", dmx(11025, std::vector<uint8_t>(1103, 0x00)));
  // 50 ms at 22050 Hz, a rate the header can carry.
  addLump("DSFAST", dmx(22050, std::vector<uint8_t>(1103, 0xFF)));
  // An upward ramp, for the resampler.
  std::vector<uint8_t> ramp(256);
  for (size_t i = 0; i < ramp.size(); ++i) ramp[i] = (uint8_t)i;
  addLump("DSRAMP", dmx(11025, ramp));
  // Malformed lumps.
  std::vector<uint8_t> wrongFormat = dmx(11025, std::vector<uint8_t>(64, 0xFF));
  wrongFormat[0] = 2;
  addLump("DSBADFMT", wrongFormat);
  std::vector<uint8_t> overlong = dmx(11025, std::vector<uint8_t>(64, 0xFF));
  overlong[4] = 0xFF;  // length past the end of the lump
  overlong[5] = 0xFF;
  addLump("DSLONG", overlong);
  addLump("DSPADS", dmx(11025, {}));  // nothing between the pads
  // DMX plays no lump of 48 or fewer: 16 samples between the pads is too
  // short, 17 is not.
  addLump("DS48", dmx(11025, std::vector<uint8_t>(16, 0xFF)));
  addLump("DS49", dmx(11025, std::vector<uint8_t>(17, 0xFF)));
  // 2 s, longer than the quit wait.
  addLump("DSLONGEST", dmx(11025, std::vector<uint8_t>(22050, 0xFF)));
  addLump("DSSHORT", {3, 0, 0x11, 0x2B});
  std::vector<uint8_t> zeroRate = dmx(0, std::vector<uint8_t>(64, 0xFF));
  addLump("DSZERO", zeroRate);

  // ---- A board without audio: sound stays off, as before. ----
  boardRate = 0;
  I_InitSound(true);
  {
    sfxinfo_t pistol = makeSfx("pistol");
    CHECK(start(pistol, 0, 127) == 0);
    CHECK(!I_SoundIsPlaying(0));
    CHECK(render == nullptr);
  }

  // ---- A board with audio. ----
  boardRate = 16000;
  I_InitSound(true);
  CHECK(render != nullptr);
  CHECK(silent(pull(64)));

  sfxinfo_t pistol = makeSfx("pistol");
  sfxinfo_t shotgun = makeSfx("shotgn");
  CHECK(I_GetSfxLumpNum(&pistol) == W_CheckNumForName((char *)"DSPISTOL"));

  // The whole sound plays at the codec's rate, identically on both channels,
  // and nothing of the DMX pads.
  {
    CHECK(start(pistol, 0, 127) == 0);
    CHECK(I_SoundIsPlaying(0));
    const std::vector<int16_t> out = pull(2000);
    bool matched = true;
    bool padPlayed = false;
    for (size_t f = 0; f < 2000; ++f) {
      if (out[2 * f] != out[2 * f + 1]) matched = false;
      if (out[2 * f] < 0) padPlayed = true;
    }
    CHECK(matched);
    CHECK(!padPlayed);
    CHECK(out[0] == 32512);  // (0xFF - 128) << 8 at full volume
    CHECK(out[2 * 1500] == 32512);
    // 1103 samples at 11025 Hz is 1600.7 frames at 16000 Hz.
    const size_t frames = audibleFrames(out);
    CHECK(frames >= 1599 && frames <= 1603);
    CHECK(!I_SoundIsPlaying(0));
  }

  // The rate in the lump header is honoured: 1103 samples at 22050 Hz.
  {
    sfxinfo_t fast = makeSfx("fast");
    CHECK(start(fast, 1, 127) == 1);
    const size_t frames = audibleFrames(pull(2000));
    CHECK(frames >= 798 && frames <= 802);
    CHECK(!I_SoundIsPlaying(1));
  }

  // Volume scales linearly; separation does not move a sound off the
  // speaker, which plays one mono mix.
  {
    CHECK(start(pistol, 0, 64) == 0);
    const std::vector<int16_t> half = pull(16);
    CHECK(half[0] == 16384 && half[1] == 16384);
    I_StopSound(0);
    for (int sep : {0, 254}) {
      CHECK(start(pistol, 0, 127, sep) == 0);
      const std::vector<int16_t> out = pull(16);
      CHECK(out[0] == 32512 && out[1] == 32512);
      I_StopSound(0);
    }
    CHECK(start(pistol, 0, 0) == 0);
    CHECK(silent(pull(16)));
    CHECK(I_SoundIsPlaying(0));
    I_StopSound(0);
  }

  // Voices sum, and clip at full scale instead of wrapping.
  {
    CHECK(start(pistol, 0, 127) == 0);
    CHECK(start(pistol, 1, 127) == 1);
    std::vector<int16_t> out = pull(16);
    CHECK(out[0] == 32767 && out[1] == 32767);
    I_StopSound(0);
    I_StopSound(1);
    CHECK(start(shotgun, 2, 127) == 2);
    CHECK(start(shotgun, 3, 127) == 3);
    out = pull(16);
    CHECK(out[0] == -32768 && out[1] == -32768);
    CHECK(start(pistol, 0, 127) == 0);  // tone + 2 x negative
    out = pull(16);
    CHECK(out[0] == -32768);
    I_StopSound(2);
    out = pull(16);
    CHECK(out[0] == 32512 - 32768);  // tone + one negative
    I_StopSound(0);
    I_StopSound(3);
    CHECK(silent(pull(16)));
  }

  // Stop, a volume change and a replacement take effect on the next frame.
  {
    CHECK(start(pistol, 4, 127) == 4);
    CHECK(!silent(pull(8)));
    I_UpdateSoundParams(4, 32, 128);
    std::vector<int16_t> out = pull(8);
    CHECK(out[0] == 8192);
    I_UpdateSoundParams(4, 127, 128);
    CHECK(pull(8)[0] == 32512);
    I_StopSound(4);
    CHECK(!I_SoundIsPlaying(4));
    CHECK(silent(pull(8)));
    CHECK(start(pistol, 4, 127) == 4);
    CHECK(start(shotgun, 4, 127) == 4);
    out = pull(8);
    CHECK(out[0] == -32768 && out[1] == -32768);
    I_StopSound(4);
  }

  // Linear interpolation between source samples: a ramp rises evenly and
  // never leaves the range of its neighbours.
  {
    sfxinfo_t rampSfx = makeSfx("ramp");
    CHECK(start(rampSfx, 5, 127) == 5);
    const std::vector<int16_t> out = pull(400);
    const size_t frames = audibleFrames(out);
    CHECK(frames >= 370 && frames <= 373);  // 256 * 16000 / 11025 = 371.5
    bool monotonic = true;
    for (size_t f = 1; f < 371; ++f) {
      if (out[2 * f] < out[2 * (f - 1)]) monotonic = false;
    }
    CHECK(monotonic);
    CHECK(out[0] == -32768);
    // Frame 100 sits at source position 68.9: between samples 68 and 69.
    CHECK(out[200] > (68 - 128) * 256 && out[200] < (69 - 128) * 256);
    CHECK(!I_SoundIsPlaying(5));
  }

  // A one-channel output gets the same mix.
  {
    CHECK(start(pistol, 0, 127) == 0);
    const std::vector<int16_t> out = pull(4, 1);
    CHECK(out[0] == 32512 && out[3] == 32512);
    I_StopSound(0);
  }

  // Links play the linked sound's lump, as the engine's linked weapon
  // sounds do.
  {
    sfxinfo_t chaingun = makeSfx("chgun", &pistol);
    CHECK(I_GetSfxLumpNum(&chaingun) == W_CheckNumForName((char *)"DSPISTOL"));
  }

  // Malformed and missing lumps, and channels past the module's, play
  // nothing and leave the output silent.
  {
    sfxinfo_t shortest = makeSfx("49");
    CHECK(start(shortest, 6, 127) == 6);
    CHECK(I_SoundIsPlaying(6));
    CHECK(audibleFrames(pull(64)) >= 23);  // 17 samples is 24.7 frames
    CHECK(!I_SoundIsPlaying(6));
    for (const char *name : {"badfmt", "long", "pads", "48", "short",
                             "zero"}) {
      sfxinfo_t bad = makeSfx(name);
      CHECK(bad.lumpnum < 0);
      bad.lumpnum = I_GetSfxLumpNum(&bad);
      CHECK(bad.lumpnum >= 0);
      I_StartSound(&bad, 6, 127, 128);
      CHECK(!I_SoundIsPlaying(6));
      CHECK(silent(pull(64)));
    }
    sfxinfo_t missing = makeSfx("nothere");
    CHECK(I_GetSfxLumpNum(&missing) < 0);
    missing.lumpnum = I_GetSfxLumpNum(&missing);
    I_StartSound(&missing, 6, 127, 128);
    CHECK(!I_SoundIsPlaying(6));
    for (int channel : {-1, 16, 99}) {
      CHECK(I_StartSound(&pistol, channel, 127, 128) < 0);
      CHECK(!I_SoundIsPlaying(channel));
      I_UpdateSoundParams(channel, 127, 128);
      I_StopSound(channel);
    }
    CHECK(silent(pull(64)));
  }

  // Every call that reads or writes the voices the output task reads does
  // so under the lock, and so does the output task's render.
  CHECK(underLock([&] { start(pistol, 0, 127); }));
  CHECK(underLock([&] { I_UpdateSoundParams(0, 64, 128); }));
  CHECK(underLock([&] { I_SoundIsPlaying(0); }));
  CHECK(underLock([&] { I_StopSound(0); }));
  CHECK(underLock([&] { pull(16); }));

  // Quitting: the quit sound plays out before the amplifier goes off, as
  // vanilla's I_WaitVBL(105) let it, but no longer than that wait.
  audibleRendered = 0;
  CHECK(start(pistol, 0, 127) == 0);
  I_ShutdownSound();
  CHECK(endCalls == 1);
  CHECK(audibleBeforeEnd >= 1599);  // all of the 100 ms sound
  CHECK(!I_SoundIsPlaying(0));
  CHECK(silent(pull(64)));
  sfxinfo_t longest = makeSfx("longest");
  audibleRendered = 0;
  CHECK(start(longest, 0, 127) == 0);
  I_ShutdownSound();
  CHECK(endCalls == 2);
  CHECK(audibleBeforeEnd >= 23000 && audibleBeforeEnd <= 24200);  // 1.5 s
  CHECK(!I_SoundIsPlaying(0));
  CHECK(silent(pull(64)));
  CHECK(beginCalls == 2);

  printf("test_doom_sound: %d checks passed\n", checks);
  return 0;
}
