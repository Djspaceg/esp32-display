// Host-side red test for the P4 task-watchdog reboot with WiFi up.
//
// On the P4 family WiFi lives on a C6 co-processor behind ESP-Hosted, so
// WiFi.RSSI() is not a register read: it is esp_wifi_sta_get_ap_info sent as
// an RPC (Req_WifiStaGetApInfo) that blocks the caller until the C6 answers or
// DEFAULT_RPC_RSP_TIMEOUT (5 s) expires. loop() arms a 10 s task watchdog and
// feeds it once per pass, so two unanswered reads in one pass - EINF's RSSI and
// the 5 s status line's, as captured on the 4C - reboot the board.
//
// The rule this asserts: loopTask never waits on a hosted WiFi RPC. The fake
// RSSI(), reconnect() and disconnect() stall the clock by the full RPC
// timeout, as a silent C6 does. wifi_worker is the one place they may run.
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <cctype>
#include <filesystem>
#include <iterator>
#include <regex>
#include <fstream>
#include <set>
#include <string>

#include "../display_stream/app_state.h"
#include "../display_stream/mdns_announce.h"
#include "../display_stream/net_link.h"
#include "../display_stream/telemetry.h"
#include "../display_stream/wifi_worker.h"
#include "../libraries/espdisp_board/src/board_config.h"
#include "fakes/audio/WiFi.h"
#include "fakes/audio/audio_host_fakes.h"

static const uint32_t HOSTED_RPC_TIMEOUT_MS = 5000;  // DEFAULT_RPC_RSP_TIMEOUT

static int failures = 0;

static void check(bool condition, const char *message) {
  if (!condition) {
    std::printf("FAIL: %s\n", message);
    failures++;
  }
}

// EINF goes out every 2 s once a sender is known. It must still go out when
// the C6 has stopped answering, and it must not take the RPC timeout to do so.
static void testDeviceInfoDoesNotWaitOnHostedRpc() {
  const board::Config *saved = bcfg;
  bcfg = &board::CONFIG_P4_4B;
  check(bcfg->platform->wifi == board::WifiTopology::HostedCoprocessor,
        "precondition: the P4 profile reaches WiFi through the C6");
  audiohost::reset();
  check(startInboundTransport(), "precondition: reply socket is open");
  audiohost::setMillis(10000);
  audiohost::setRssiRpcStallMs(HOSTED_RPC_TIMEOUT_MS);
  hbIp = 0x0a000002;
  hbPort = 5569;

  sendDeviceInfo();

  check(audiohost::sentDatagrams().size() == 1, "EINF is still sent");
  check(audiohost::rssiRpcCalls() == 0,
        "sendDeviceInfo issues no hosted RSSI RPC on the calling task");
  check(millis() - 10000 < HOSTED_RPC_TIMEOUT_MS,
        "sendDeviceInfo returns well inside one hosted RPC timeout");
  hbPort = 0;
  bcfg = saved;
}

// A C6 that stops answering while associated is reported, so the supervisor
// can restart the board as the watchdog reboot once did by accident.
static void testSilentCoprocessorIsReported() {
  audiohost::reset();
  check(wifiworker::start(), "worker starts");
  audiohost::setMillis(100000);
  WiFi.setStatus(0);
  wifiworker::serviceOnce(0);
  WiFi.setStatus(WL_CONNECTED);
  audiohost::setRssiValue(0);  // every RSSI RPC times out
  audiohost::setRssiRpcStallMs(HOSTED_RPC_TIMEOUT_MS);
  for (int i = 0; i < 5; i++) wifiworker::serviceOnce(0);
  check(millis() - 100000 < wifiworker::COPROCESSOR_SILENT_MS &&
            !wifiworker::coprocessorSilent(),
        "not silent inside the window");
  for (int i = 0; i < 3; i++) wifiworker::serviceOnce(0);
  check(wifiworker::coprocessorSilent(),
        "associated with no RSSI answer for 30 s is silent");
  audiohost::setRssiValue(-50);
  wifiworker::serviceOnce(0);
  check(!wifiworker::coprocessorSilent() && wifiworker::rssi() == -50,
        "one answer clears it");
  // The SSID read that follows an answer may itself stall the fake clock,
  // so the age right after is small rather than exactly zero.
  uint32_t answerAge = 0;
  check(wifiworker::lastAnswerAgeMs(millis(), answerAge) &&
            answerAge <= HOSTED_RPC_TIMEOUT_MS,
        "the mem line's rpcage is small right after an answer");
  uint32_t laterAge = 0;
  check(wifiworker::lastAnswerAgeMs(millis() + 750, laterAge) &&
            laterAge == answerAge + 750,
        "rpcage counts from the last answer");
  check(wifiworker::lastAnswerAgeMs(millis() - answerAge - 5, laterAge) &&
            laterAge == 0,
        "an answer newer than the caller's clock reads as zero, not a wrap");
  WiFi.setStatus(0);
  audiohost::setRssiValue(0);
  audiohost::setMillis(millis() + 1000);
  wifiworker::serviceOnce(0);
  check(!wifiworker::coprocessorSilent(), "never silent while not associated");
  check(!wifiworker::lastAnswerAgeMs(millis(), answerAge),
        "no rpcage while not associated");
  check(wifiworker::rssi() == 0, "a dropped link keeps no RSSI sample");
}

static int16_t einfRssi(const audiohost::SentDatagram &datagram) {
  return (int16_t)(datagram.data[16] | (datagram.data[17] << 8));
}

// The worker takes the RPC and its stall; EINF then carries that sample, and
// reports unknown (0) once the sample is older than the staleness window.
static void testWorkerSampleReachesDeviceInfo() {
  audiohost::reset();
  check(startInboundTransport(), "precondition: reply socket is open");
  check(wifiworker::start(), "worker starts");
  audiohost::setMillis(20000);
  audiohost::setRssiRpcStallMs(HOSTED_RPC_TIMEOUT_MS);
  wifiworker::serviceOnce(0);
  check(audiohost::rssiRpcCalls() == 1, "the worker issues the RSSI RPC");
  check(wifiworker::rssi() == -42, "the worker's sample is cached");

  hbIp = 0x0a000002;
  hbPort = 5569;
  const uint32_t before = millis();
  sendDeviceInfo();
  check(millis() == before, "EINF does not wait once the sample is cached");
  check(audiohost::sentDatagrams().size() == 1 &&
            einfRssi(audiohost::sentDatagrams()[0]) == -42,
        "EINF carries the worker's RSSI sample");

  audiohost::setMillis(before + wifiworker::RSSI_STALE_MS + 1);
  check(wifiworker::rssi() == 0, "a stale sample reads as unknown");
  sendDeviceInfo();
  check(audiohost::sentDatagrams().size() == 2 &&
            einfRssi(audiohost::sentDatagrams()[1]) == -127,
        "EINF sends an unknown RSSI as -127, not 0");
  hbPort = 0;
}

// Reconnects are posted, run on the worker, and their result comes back once.
static void testReconnectRunsOnWorker() {
  audiohost::reset();
  check(wifiworker::start(), "worker starts");
  audiohost::setRssiRpcStallMs(HOSTED_RPC_TIMEOUT_MS);
  bool accepted = false;
  wifiworker::requestReconnect();
  check(audiohost::linkRpcCalls() == 0 && millis() == 0,
        "requestReconnect does not wait on the RPC");
  check(!wifiworker::takeReconnectResult(accepted), "no result before it runs");
  wifiworker::serviceOnce(0);
  check(audiohost::linkRpcCalls() == 1, "the worker runs the reconnect");
  check(wifiworker::takeReconnectResult(accepted) && accepted,
        "the reconnect result is reported");
  check(!wifiworker::takeReconnectResult(accepted), "and only once");
  wifiworker::requestReassociate();
  wifiworker::serviceOnce(0);
  check(audiohost::linkRpcCalls() == 3,
        "reassociate runs disconnect and reconnect on the worker");
  check(!wifiworker::takeReconnectResult(accepted),
        "a reassociate does not report to the supervisor");
}

// mDNS names the joined network from the worker's reading. The announce, the
// loop's 5 s check and the restart path all run on loopTask, so none of them
// may issue the SSID RPC or wait on it.
static void testMdnsReadsTheWorkersSsid() {
  audiohost::reset();
  check(wifiworker::start(), "worker starts");
  audiohost::setMillis(200000);
  WiFi.setStatus(0);
  wifiworker::serviceOnce(0);  // a dropped link forgets the last reading
  char read[33];
  check(!wifiworker::ssid(read, sizeof(read)) && read[0] == 0,
        "no SSID reading while the link is down");

  WiFi.setStatus(WL_CONNECTED);
  WiFi.setSSID("HomeNet");
  audiohost::setRssiValue(0);  // the C6 is silent
  audiohost::setRssiRpcStallMs(HOSTED_RPC_TIMEOUT_MS);
  check(mdnsSsidIsCurrent() && audiohost::ssidRpcCalls() == 0,
        "no reading yet is not a change, and costs no RPC");
  wifiworker::serviceOnce(0);
  check(audiohost::ssidRpcCalls() == 0,
        "a C6 that does not answer RSSI is not asked for the SSID");
  audiohost::setRssiValue(-50);
  audiohost::setMillis(millis() + wifiworker::RSSI_POLL_MS);
  wifiworker::serviceOnce(0);
  check(audiohost::ssidRpcCalls() == 1,
        "the worker reads the SSID once the C6 answers");
  check(wifiworker::ssid(read, sizeof(read)) && std::string(read) == "HomeNet",
        "the worker's SSID reading is cached");

  const unsigned rpcsBefore = audiohost::ssidRpcCalls();
  const uint32_t before = millis();
  check(!mdnsSsidIsCurrent(), "a reading the announcement lacks is a change");
  check(restartMdnsService(), "precondition: mDNS restarts");
  check(mdnsSsidIsCurrent(), "the re-announce names the worker's reading");
  addMdnsService();
  check(audiohost::ssidRpcCalls() == rpcsBefore && millis() == before,
        "announce, check and restart issue no SSID RPC and never wait");

  audiohost::setRssiRpcStallMs(0);
  audiohost::setMillis(millis() + wifiworker::RSSI_POLL_MS);
  wifiworker::serviceOnce(0);
  check(audiohost::ssidRpcCalls() == rpcsBefore,
        "one reading per association, not one per pass");

  WiFi.setSSID("");  // the RPC fails
  wifiworker::requestReassociate();
  audiohost::setMillis(millis() + wifiworker::RSSI_POLL_MS);
  wifiworker::serviceOnce(0);
  check(audiohost::ssidRpcCalls() == rpcsBefore + 1,
        "a reassociate run here owes a fresh reading");
  check(wifiworker::ssid(read, sizeof(read)) && std::string(read) == "HomeNet",
        "a failed SSID read keeps this association's reading");
  audiohost::setMillis(millis() + wifiworker::RSSI_POLL_MS);
  wifiworker::serviceOnce(0);
  check(audiohost::ssidRpcCalls() == rpcsBefore + 1,
        "a failed read is not retried every pass");
  WiFi.setSSID("OtherNet");
  audiohost::setMillis(millis() + wifiworker::SSID_POLL_MS);
  wifiworker::serviceOnce(0);
  check(wifiworker::ssid(read, sizeof(read)) && std::string(read) == "OtherNet",
        "the retry lands once the C6 answers it");
  WiFi.setStatus(0);
  wifiworker::serviceOnce(0);
}

// Each of these is an ESP-Hosted RPC on P4 that can stall its caller by 5 s.
// Only the worker may issue them after setup(); the rest of the firmware
// reads wifiworker::rssi() and posts reconnects. setup()'s WiFi.mode() and
// WiFi.begin() run before loopTask joins the watchdog, so they are not listed.
// Whitespace and newlines around the '.' are allowed, and WiFi.STA.* counts.
static const std::regex HOSTED_RPC_CALL(
    R"((\bWiFi\s*\.\s*(STA\s*\.\s*)?)"
    R"((RSSI|reconnect|disconnect\w*|SSID|BSSID\w*|channel|scanNetworks\w*|)"
    R"(setTxPower|getTxPower)\s*\()"
    R"(|\bSTA\s*\.\s*(RSSI|reconnect|disconnect|SSID|BSSID\w*|channel)\s*\()"
    R"(|\besp_wifi_\w+\s*\(|\besp_hosted_\w+\s*\(|\bhostedGet\w+\s*\())");

// Files allowed to issue those calls, and why.
static const std::set<std::string> OFF_LOOP_RPC_FILES = {
    "wifi_worker.cpp",   // the worker task itself
    "fault_inject.cpp",  // bench-only, compiled in only on request; its RPCs
                         // run on side tasks it spawns
};

// The source with // and /* */ comments and string contents blanked out (newlines kept, so
// offsets still map to line numbers).
static std::string withoutComments(const std::string &text) {
  std::string out = text;
  for (size_t i = 0; i + 1 < out.size(); i++) {
    if (out[i] == '/' && out[i + 1] == '/') {
      while (i < out.size() && out[i] != '\n') out[i++] = ' ';
    } else if (out[i] == '/' && out[i + 1] == '*') {
      while (i + 1 < out.size() && !(out[i] == '*' && out[i + 1] == '/')) {
        if (out[i] != '\n') out[i] = ' ';
        i++;
      }
      if (i + 1 < out.size()) out[i] = out[i + 1] = ' ';
    } else if (out[i] == '"') {
      for (i++; i < out.size() && out[i] != '"' && out[i] != '\n'; i++) {
        if (out[i] == '\\' && i + 1 < out.size()) out[i++] = ' ';
        out[i] = ' ';
      }
    }
  }
  return out;
}

static int scanForHostedRpcs(const std::filesystem::path &root) {
  int sites = 0;
  for (const auto &entry :
       std::filesystem::recursive_directory_iterator(root)) {
    if (!entry.is_regular_file()) continue;
    const std::string ext = entry.path().extension().string();
    if (ext != ".cpp" && ext != ".c" && ext != ".h" && ext != ".ino") continue;
    const std::string name = entry.path().filename().string();
    if (OFF_LOOP_RPC_FILES.count(name) != 0) continue;
    std::ifstream in(entry.path());
    const std::string text((std::istreambuf_iterator<char>(in)),
                           std::istreambuf_iterator<char>());
    const std::string code = withoutComments(text);
    for (auto it = std::sregex_iterator(code.begin(), code.end(),
                                        HOSTED_RPC_CALL);
         it != std::sregex_iterator(); ++it) {
      const long line =
          1 + std::count(code.begin(), code.begin() + it->position(), '\n');
      std::string call = it->str();
      call.erase(std::remove_if(call.begin(), call.end(), ::isspace),
                 call.end());
      std::printf("  loopTask hosted RPC %s: %s:%ld\n", call.c_str(),
                  name.c_str(), line);
      sites++;
    }
  }
  return sites;
}

static void testNoHostedRpcsOutsideWorker() {
  const std::filesystem::path firmware =
      std::filesystem::path(__FILE__).parent_path() / "..";
  int sites = scanForHostedRpcs(firmware / "display_stream");
  sites += scanForHostedRpcs(firmware / "libraries");
  check(sites == 0, "no hosted WiFi RPC outside the WiFi worker");
}

// The scanner itself: multi-line and STA spellings are caught, comments and
// strings are not.
static void testScannerCatchesSpellings() {
  const char *hits[] = {"WiFi\n  .RSSI()", "WiFi . reconnect()",
                        "WiFi.STA.RSSI()", "STA.disconnect()",
                        "esp_wifi_sta_get_ap_info(&i)",
                        "esp_hosted_get_cp_info(a, b, c)", "hostedGetSlaveVersion(",
                        "WiFi.disconnectAsync()", "WiFi.setTxPower(x)"};
  for (const char *hit : hits) {
    const std::string code = withoutComments(hit);
    check(std::regex_search(code, HOSTED_RPC_CALL), hit);
  }
  const char *misses[] = {"// WiFi.RSSI()", "/* WiFi.reconnect() */",
                          "\"WiFi.RSSI()\"", "WiFi.status()",
                          "WiFi.localIP()", "wifiworker::rssi()"};
  for (const char *miss : misses) {
    const std::string code = withoutComments(miss);
    check(!std::regex_search(code, HOSTED_RPC_CALL), miss);
  }
}

int main() {
  testDeviceInfoDoesNotWaitOnHostedRpc();
  testWorkerSampleReachesDeviceInfo();
  testReconnectRunsOnWorker();
  testSilentCoprocessorIsReported();
  testMdnsReadsTheWorkersSsid();
  testScannerCatchesSpellings();
  testNoHostedRpcsOutsideWorker();
  if (failures != 0) {
    std::printf("hosted rpc budget: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("hosted rpc budget: all checks passed\n");
  return 0;
}
