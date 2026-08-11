// The OTA decisions that are pure logic: what a CFGOTAPW argument means, whether
// a decoded password is acceptable, and how the two OTA flags become the one
// thing the sender and CFGSHOW are told.
//
// All three were inline in the sketch, tangled with Preferences, ESP.restart(),
// and mbedtls, so none of them could be reached from a test - and the most
// important of them is the 8-byte floor, which is the only thing standing between
// the LAN and a firmware write. Nothing proved that 7 bytes is refused.
//
// The decode itself stays in the sketch: mbedtls is not available to the host
// test, and base64 is not the part with a decision in it. verifyPassword takes
// the decode's outcome and length as inputs instead.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace otapolicy {

/// Bounds on the decoded password, in bytes.
///
/// The floor is the security-relevant one. espota can be retried as fast as the
/// panel will answer, there is no lockout, and a successful guess is a firmware
/// write - so a weak password here is worse than having no OTA at all, which is
/// the state every panel ships in.
///
/// The ceiling is ArduinoOTA's practical limit rather than a security property;
/// it exists so the sketch can size a fixed decode buffer and so an absurd
/// argument is refused with a specific message rather than a base64 error.
static const size_t PASSWORD_MIN_BYTES = 8;
static const size_t PASSWORD_MAX_BYTES = 64;

/// The literal argument that forgets the password and so turns OTA off again.
static const char CLEAR_TOKEN[] = "clear";

/// What the sketch does with a CFGOTAPW argument.
enum class Argument : uint8_t {
  // Forget the stored password. OTA goes back off.
  Clear,
  // Base64 of a new password, to be decoded and then checked by verifyPassword.
  Payload,
};

/// Decide whether an argument is the off switch or a password payload.
///
/// The order matters and is the whole reason this is a separate step: the literal
/// is recognised BEFORE any decode is attempted, so "clear" cannot be mistaken
/// for a password no matter what a base64 decoder would make of those five
/// characters. The sketch's comment used to claim the collision was impossible
/// because "five characters can never be valid base64" - that is a claim about
/// decoders, not about the string. Every character of "clear" is in the base64
/// alphabet (see the test), and decoders differ on whether they insist on
/// padding, so the claim is not one to lean on. The ordering here is, and it
/// holds regardless of which decoder is underneath.
inline Argument classifyArgument(const char *arg) {
  if (arg != nullptr && strcmp(arg, CLEAR_TOKEN) == 0) return Argument::Clear;
  return Argument::Payload;
}

/// Why a password payload was accepted or refused.
enum class Verdict : uint8_t {
  Accept,
  // The argument was not decodable base64 at all.
  NotBase64,
  // Decoded to bytes that cannot survive being stored or used, because every
  // layer underneath handles the password as a C string. See verifyPassword.
  EmbeddedNul,
  // Decoded, but below PASSWORD_MIN_BYTES.
  TooShort,
  // Decoded, but above PASSWORD_MAX_BYTES.
  TooLong,
};

/// Judge a decoded password: it must be storable, then long enough.
///
/// `decoded` is whether the base64 decode succeeded; `bytes`/`decodedBytes` are
/// what it produced. Taking the outcome and the bytes as inputs keeps mbedtls out
/// of this header while putting every judgement about the result where it can be
/// tested - which is the point, because the length policy used to be checked here
/// and then applied to something else entirely.
///
/// WHY A 0x00 BYTE IS REFUSED, and why here: every layer below this one handles
/// the password as a NUL-terminated C string, so a decoded password containing a
/// 0x00 is silently cut short at that byte and the length judged here stops
/// describing the secret in use.
///   - Preferences::putString(const char *) calls nvs_set_str, which stores up to
///     the terminator (core Preferences.cpp), so a 16-byte password whose fourth
///     byte is zero is stored as 3 bytes.
///   - ArduinoOTA::setPassword(const char *) hashes with SHA256Builder::add(const
///     char *), so the same truncation happens again in the hash.
///   - espota.py takes the password as an argv string, which cannot carry a 0x00
///     at all - so the pusher could not send the full password even if the panel
///     had stored it.
/// A password with an embedded 0x00 therefore cannot work end to end no matter
/// where it is fixed up, and the failure is silent: the panel would advertise
/// CAP_OTA and listen with a secret shorter than the floor promises. This is not
/// exotic input - `CFGOTAPW $(head -c 16 /dev/urandom | base64)` is the natural
/// way to make a strong password, and 16 random bytes contain a zero about 6% of
/// the time. Refusing tells the user to try again, which costs one command; the
/// alternative is a weakened panel and no way to notice.
///
/// Checked before the bounds so the answer names the disqualifying property
/// rather than a length that was never going to be the stored length anyway. The
/// accepted set is otherwise unchanged: exactly 8..64 bytes, none of them zero.
///
/// An empty payload lands in TooShort rather than getting its own verdict: a
/// bare `CFGOTAPW` never reaches here (the command needs its trailing space),
/// and "too short" is the truthful answer for zero bytes anyway.
inline Verdict verifyPassword(bool decoded, const unsigned char *bytes,
                              size_t decodedBytes) {
  if (!decoded) return Verdict::NotBase64;
  // No bytes to inspect but a length claiming otherwise is not something to
  // guess about; treat it as a decode that cannot be trusted.
  if (bytes == nullptr && decodedBytes > 0) return Verdict::NotBase64;
  // Guarded rather than relying on memchr(nullptr, 0, 0) being harmless.
  if (decodedBytes > 0 && memchr(bytes, 0, decodedBytes) != nullptr) {
    return Verdict::EmbeddedNul;
  }
  if (decodedBytes < PASSWORD_MIN_BYTES) return Verdict::TooShort;
  if (decodedBytes > PASSWORD_MAX_BYTES) return Verdict::TooLong;
  return Verdict::Accept;
}

/// What OTA the panel actually has, from the two flags the sketch keeps.
enum class Status : uint8_t {
  // No password stored. OTA is off and cannot come up.
  Off,
  // A password is stored, but nothing is listening yet - the radio was not up
  // when setup ran, or begin() has not been reached.
  Pending,
  // Listening: begin() has run and handle() is live.
  On,
};

/// Collapse the two flags into one status.
///
/// Three-valued rather than a boolean because the distinction is real: a panel
/// with a stored password whose WiFi was not up when it booted is correctly
/// configured and merely waiting, and reporting that as "off" would make it look
/// misconfigured to whoever set the password.
///
/// `active` implies `configured` in the sketch, since OTA cannot start without a
/// password - but this does not depend on that, so a bug that ever broke the
/// implication still reports the state that matters: something is listening.
inline Status status(bool active, bool configured) {
  if (active) return Status::On;
  return configured ? Status::Pending : Status::Off;
}

/// The token CFGSHOW prints for ota=.
inline const char *statusToken(Status status) {
  switch (status) {
    case Status::On:
      return "on";
    case Status::Pending:
      return "pending";
    case Status::Off:
      break;
  }
  return "off";
}

/// Whether the advertised capability set should carry CAP_OTA.
///
/// Keyed to On alone, deliberately. A Pending panel must NOT advertise OTA: the
/// bit tells a sender it may offer an update, and nothing is listening to accept
/// one, so advertising it would produce a push that times out rather than an
/// update. This is the one place the capability bit and the reported status are
/// allowed to disagree, and they disagree in the safe direction.
inline bool advertisesCapability(Status status) { return status == Status::On; }

}  // namespace otapolicy
