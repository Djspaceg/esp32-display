// Which chip this binary was built for, as the one token the panel advertises.
//
// WHY THE PANEL SAYS IT RATHER THAN THE APP GUESSING. A firmware bundle carries
// one image per chip, and whoever opens that bundle - the Mac app, on another
// machine, weeks later - has to pick one. The only thing it knows about a panel
// today is what the _espdisp._udp TXT records say, and none of them name the
// chip. It could be inferred from `res=WxH`, and that would work right now,
// because 172x320 happens to mean C6 and 466x466 happens to mean S3. It works
// only by coincidence of the current board set, and the firmware was made
// resolution-parametric (bandproto::Geometry, board::Config) specifically so
// that coincidence can end: two panels of the same size on different chips, or
// one chip driving a new size, both break the inference silently and the app
// would push a C6 image at an S3.
//
// The cost of saying it instead is one TXT record: "chip=esp32c6" is twelve
// bytes plus the length byte mDNS puts in front of every TXT string, announced
// with the records already there. What it buys is the difference between
// guessing and knowing: the app can refuse a definite mismatch ("this bundle has
// no esp32s3 image") instead of pushing the wrong image and learning it from the
// panel, which cannot tell until the whole two megabytes have crossed the LAN -
// the ESP image header's chip_id is checked by esp_ota_set_boot_partition, so a
// wrong-chip push is refused safely, but only at the end.
//
// THE VOCABULARY IS THE IDF'S, NOT OURS. The token is the IDF's own
// CONFIG_IDF_TARGET string, which expands to exactly "esp32c6"
// (esp32c6-libs/3.3.11/qio_qspi/include/sdkconfig.h:429) and exactly "esp32s3"
// (esp32s3-libs/3.3.11/*/include/sdkconfig.h:394) in the core this firmware is
// built with. Those are byte-identical to tools/espdisp.py's BOARDS[*].chip, to
// the `chip` field in a .espdispfw manifest, and to the `board=` record on the
// separate _arduino._tcp service, which the core fills in from ARDUINO_VARIANT
// (ESPmDNS.cpp:114) and which boards.txt sets to esp32c6 and esp32s3 for these
// two FQBNs (lines 810 and 1187). So the TXT record, the bundle, the CLI and the
// app all spell the chip the same way, and no layer needs a translation table
// that can rot.
//
// UNVERIFIED: that a real panel publishes this record and that a browser sees
// it. No board is attached to the machine this was written on, so what is known
// is that ESPmDNS::addServiceTxt is the same call the existing name/res/fw/
// proto/caps records go through and those are observed to work. The record's
// arrival has not been measured this session.
#pragma once

// The IDF's generated sdkconfig.h is where both CONFIG_IDF_TARGET and the
// CONFIG_IDF_TARGET_<CHIP> flags come from. The Arduino build already pulls it
// in through Arduino.h, but this header asks for it itself so it does not
// depend on include order in the sketch, and so it stays compilable on the host
// where that file is nowhere on the include path - which is the whole reason the
// ladder below has a defined final rung.
#if defined(__has_include)
#if __has_include(<sdkconfig.h>)
#include <sdkconfig.h>
#endif
#endif

namespace chipidentity {

/// The tokens, spelled once.
///
/// Keep these byte-identical to tools/espdisp.py BOARDS[*].chip. They are only
/// reached through the fallback rungs below - a real build answers with the
/// IDF's own string - but they are what the static_asserts at the bottom of this
/// file check that string against, so a drift between the two vocabularies is a
/// compile error on the affected target rather than a wrong image on a panel.
///
/// constexpr rather than the `static const char[]` the neighbouring headers use,
/// and for a reason rather than for fashion: those static_asserts read these
/// characters during compilation, and a `const` array is not a constant
/// expression to read from.
static constexpr char TOKEN_ESP32C6[] = "esp32c6";
static constexpr char TOKEN_ESP32S3[] = "esp32s3";

/// What a build that cannot name its chip advertises.
///
/// This is "I could not tell", NOT "some other chip", and the difference is the
/// whole reason it is a defined token rather than an omitted record. A reader
/// must treat it as missing knowledge and fall back to whatever it did before
/// (asking, or offering every image it has), because refusing on it would turn
/// a build this header failed to recognise into a panel nothing can update.
/// Only a token that names a DIFFERENT chip is a contradiction worth refusing -
/// the same three-valued stance verify_ota_target takes in tools/espdisp.py,
/// where a panel mDNS cannot find is a note and a panel that answers with the
/// wrong chip is a refusal.
static constexpr char TOKEN_UNKNOWN[] = "unknown";

/// Equality for two tokens, usable in a constant expression.
///
/// strcmp is not constexpr, and the point of having this at all is the
/// static_asserts at the bottom: they compare the IDF's string against this
/// file's own tokens while the target is being compiled, which is the only
/// place that comparison can be made for a real build.
constexpr bool sameToken(const char *a, const char *b) {
  if (a == nullptr || b == nullptr) return a == b;
  while (*a != '\0' && *a == *b) {
    a++;
    b++;
  }
  return *a == *b;
}

/// The ladder, with its inputs as arguments instead of as macros.
///
/// Every rung is reachable from a host test this way, which is the reason for
/// the shape: the preprocessor state of a translation unit is fixed, so a test
/// that only called chipToken() could prove exactly one branch and would prove
/// it for the host, the one build nobody ships.
///
/// CONFIG_IDF_TARGET wins when it is there because it is the IDF's own answer
/// and it stays right for a chip this file has never heard of. The two booleans
/// are the fallback for a build where the string is missing but the per-chip
/// flag is not, and they are ordered rather than exclusive so that a build
/// somehow claiming both still answers with one token instead of nothing.
constexpr const char *selectToken(const char *idfTarget, bool isEsp32C6,
                                  bool isEsp32S3) {
  // An empty string is treated as absent: a defined-but-blank CONFIG_IDF_TARGET
  // would otherwise be advertised as a chip named "", which reads to the app as
  // a definite mismatch with every image in a bundle rather than as ignorance.
  if (idfTarget != nullptr && idfTarget[0] != '\0') return idfTarget;
  if (isEsp32C6) return TOKEN_ESP32C6;
  if (isEsp32S3) return TOKEN_ESP32S3;
  return TOKEN_UNKNOWN;
}

// The three things the preprocessor knows, each as its own constexpr answer.
//
// Split out rather than written inline in chipToken() so the ladder can be
// evaluated from a static_assert with only SOME of them supplied - which is what
// makes the flag wiring checkable at all. Fed straight into chipToken() they
// would be unreachable: a wrong `#if` in a branch the host does not compile is
// invisible to a host test, and on a real build CONFIG_IDF_TARGET wins before
// the flags are consulted, so nothing would notice either. The assert below
// asks the flags on their own.

/// The IDF's own target string, or nullptr on a build that has none (the host).
constexpr const char *buildIdfTarget() {
#if defined(CONFIG_IDF_TARGET)
  return CONFIG_IDF_TARGET;
#else
  return nullptr;
#endif
}

/// Whether the IDF's per-chip flag for the C6 is set.
constexpr bool buildTargetsEsp32C6() {
#if defined(CONFIG_IDF_TARGET_ESP32C6)
  return true;
#else
  return false;
#endif
}

/// Whether the IDF's per-chip flag for the S3 is set.
constexpr bool buildTargetsEsp32S3() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  return true;
#else
  return false;
#endif
}

/// What this build says it is: the preprocessor's answers, handed to the ladder.
constexpr const char *chipToken() {
  return selectToken(buildIdfTarget(), buildTargetsEsp32C6(),
                     buildTargetsEsp32S3());
}

// The two vocabularies checked against each other, on the target, at compile
// time. A real build defines both CONFIG_IDF_TARGET and its CONFIG_IDF_TARGET_
// flag, so these are the checks that the fallback rungs of the ladder answer
// with the same string the IDF does - the one thing a host test cannot see,
// because neither macro exists there. Compiled for both targets on every build,
// so a token renamed on one side fails the build of the affected chip.
#if defined(CONFIG_IDF_TARGET) && defined(CONFIG_IDF_TARGET_ESP32C6)
static_assert(sameToken(CONFIG_IDF_TARGET, TOKEN_ESP32C6),
              "CONFIG_IDF_TARGET disagrees with TOKEN_ESP32C6: the advertised "
              "chip= token would no longer match tools/espdisp.py BOARDS.");
#endif
#if defined(CONFIG_IDF_TARGET) && defined(CONFIG_IDF_TARGET_ESP32S3)
static_assert(sameToken(CONFIG_IDF_TARGET, TOKEN_ESP32S3),
              "CONFIG_IDF_TARGET disagrees with TOKEN_ESP32S3: the advertised "
              "chip= token would no longer match tools/espdisp.py BOARDS.");
#endif

// And the flag wiring itself, which is the part nothing else can reach. For a
// chip this header has a fallback for, the flags ON THEIR OWN must name the same
// one the IDF's string does - so a `#if` that tests the wrong macro, or answers
// the wrong way round, fails the build of the target it is wrong about.
//
// The nullptr is the load-bearing argument and is written here rather than
// wrapped in a helper on purpose: passing buildIdfTarget() instead would make
// this compare CONFIG_IDF_TARGET against a ladder that was handed
// CONFIG_IDF_TARGET, i.e. against itself, and the check would pass for every
// possible wiring. Hidden behind a plausible name that edit looks harmless; here
// it does not.
//
// Deliberately silent about a chip with no fallback rung: a hypothetical esp32p4
// build has neither flag, the ladder answers "unknown", and this must not turn
// that into a compile error. Such a build advertises the IDF's string correctly
// anyway, which is the whole reason that rung comes first.
#if defined(ESP_PLATFORM) && defined(CONFIG_IDF_TARGET)
static_assert(!(sameToken(CONFIG_IDF_TARGET, TOKEN_ESP32C6) ||
                sameToken(CONFIG_IDF_TARGET, TOKEN_ESP32S3)) ||
                  sameToken(CONFIG_IDF_TARGET,
                            selectToken(nullptr, buildTargetsEsp32C6(),
                                        buildTargetsEsp32S3())),
              "The CONFIG_IDF_TARGET_<CHIP> ladder does not agree with "
              "CONFIG_IDF_TARGET about which chip this is.");
#endif

// And on any ESP build, that the ladder found an answer at all. ESP_PLATFORM is
// defined by the core's own compile flags (esp32c6-libs/3.3.11/flags/defines),
// so this fires for the firmware and not for the host test, where "unknown" is
// the correct and expected answer.
//
// Worth catching here rather than on the glass: if sdkconfig.h ever stopped
// being reachable from this translation unit, nothing would break, nothing
// would warn, and every panel would quietly advertise chip=unknown - which the
// app is required to treat as ignorance, so the whole feature would degrade to
// exactly the guessing it exists to replace. A build failure is a much cheaper
// way to find that out.
#if defined(ESP_PLATFORM)
static_assert(!sameToken(chipToken(), TOKEN_UNKNOWN),
              "This build cannot name its chip: sdkconfig.h did not reach "
              "chip_identity.h, so the panel would advertise chip=unknown.");
#endif

}  // namespace chipidentity
