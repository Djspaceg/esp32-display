// Host test for the 5 s "mem" diagnostic line (display_stream/mem_report.h):
// the status line before it is unchanged, so the app's and the tools'
// parsers are untouched, and the mem line itself parses as key=value fields.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <regex>
#include <string>
#include <vector>

#include "../display_stream/mem_report.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

static std::string sourceText(const char *relative) {
  std::string here = __FILE__;
  const size_t slash = here.find_last_of('/');
  const std::string dir = slash == std::string::npos ? "." : here.substr(0, slash);
  std::ifstream input(dir + "/" + relative);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

// The status line statement exactly as it was before the mem line existed.
static const char STATUS_STATEMENT[] =
    "    serialout::printfLine(Serial,\n"
    "                  \"frames=%lu dropped=%lu partial=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d\",\n"
    "                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,\n"
    "                  (unsigned long)statFramesPartial, (unsigned long)statPackets,\n"
    "                  (unsigned long)statBadLen, (unsigned long)statDrawErrors,\n"
    "                  (unsigned long)ESP.getFreeHeap(), wifiworker::rssi());\n";

static int statusLineUnchangedAndMemLineFollows() {
  const std::string sketch = sourceText("../display_stream/display_stream.ino");
  CHECK(!sketch.empty());
  const size_t guard = sketch.find("serialout::LineGuard reportGuard;");
  CHECK(guard != std::string::npos);
  const size_t status = sketch.find(STATUS_STATEMENT);
  CHECK(status != std::string::npos);
  CHECK(sketch.find(STATUS_STATEMENT, status + 1) == std::string::npos);
  CHECK(status > guard);
  // The mem line is the very next thing printed, inside the same guard.
  const size_t afterStatus = status + strlen(STATUS_STATEMENT);
  const size_t mem = sketch.find("memreport::formatLine(", afterStatus);
  CHECK(mem != std::string::npos);
  const size_t memPrint = sketch.find("serialout::printfLine(Serial, \"%s\", memLine);", mem);
  CHECK(memPrint != std::string::npos);
  const std::string between = sketch.substr(afterStatus, mem - afterStatus);
  CHECK(between.find("printfLine") == std::string::npos);
  CHECK(between.find("Serial.") == std::string::npos);
  const size_t tileStats = sketch.find("reportTileDrawStats();", afterStatus);
  CHECK(tileStats != std::string::npos && memPrint < tileStats);
  return 0;
}

// The tools read the status line with these (tools/measure_sched_arms.py,
// tools/measure_record_layouts.py). The mem line must not match them either.
static const std::regex FRAMES_RE(
    "frames=(\\d+) dropped=(\\d+) partial=(\\d+) packets=(\\d+)");

static int statusLineStillParses() {
  char line[256];
  snprintf(line, sizeof(line),
           "frames=%lu dropped=%lu partial=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d",
           1001UL, 212UL, 0UL, 9512UL, 0UL, 0UL, 121516UL, -55);
  std::cmatch m;
  CHECK(std::regex_search(line, m, FRAMES_RE));
  CHECK(m[1] == "1001" && m[4] == "9512");
  return 0;
}

struct Field {
  std::string key;
  std::string value;
};

static std::vector<Field> parseMemLine(const std::string &line) {
  std::vector<Field> fields;
  size_t at = 0;
  bool first = true;
  while (at < line.size()) {
    size_t end = line.find(' ', at);
    if (end == std::string::npos) end = line.size();
    const std::string token = line.substr(at, end - at);
    at = end + 1;
    if (first) {
      first = false;
      if (token != "mem") return {};
      continue;
    }
    const size_t eq = token.find('=');
    if (eq == std::string::npos || eq == 0 || eq + 1 == token.size()) return {};
    fields.push_back({token.substr(0, eq), token.substr(eq + 1)});
  }
  return fields;
}

static bool parsesAsInteger(const std::string &text, long long &out) {
  char *end = nullptr;
  out = strtoll(text.c_str(), &end, 0);
  return end != nullptr && *end == 0 && !text.empty();
}

static const char *const KEYS[] = {"ifree", "imin",  "dma",   "dmamin",
                                   "dmablk", "afail", "afsz",  "afcaps",
                                   "rpcage", "aupErr"};

static int memLineParses(const memreport::Sample &sample, size_t bufferBytes) {
  char line[192];
  CHECK(bufferBytes <= sizeof(line));
  const int written = memreport::formatLine(line, bufferBytes, sample);
  CHECK(written > 0 && (size_t)written < bufferBytes);  // never truncated
  CHECK(strchr(line, '\n') == nullptr);
  CHECK(strstr(line, "CFG") == nullptr);  // not a config reply marker
  CHECK(!std::regex_search(line, FRAMES_RE));
  CHECK(strstr(line, "frames=") == nullptr);

  const std::vector<Field> fields = parseMemLine(line);
  CHECK(fields.size() == sizeof(KEYS) / sizeof(KEYS[0]));
  long long values[sizeof(KEYS) / sizeof(KEYS[0])];
  for (size_t i = 0; i < fields.size(); i++) {
    CHECK(fields[i].key == KEYS[i]);
    CHECK(parsesAsInteger(fields[i].value, values[i]));
  }
  CHECK(values[0] == sample.internalFree);
  CHECK(values[4] == sample.dmaLargestBlock);
  CHECK(values[5] == sample.allocFailures);
  CHECK(values[7] == sample.lastFailedCaps);
  CHECK(values[8] == sample.rpcAgeMs);
  CHECK(values[9] == sample.uplinkErrors);
  return 0;
}

int main() {
  if (statusLineUnchangedAndMemLineFollows() != 0) return 1;
  if (statusLineStillParses() != 0) return 1;

  // No hosted link, nothing failed yet: rpcage reads -1.
  memreport::Sample fresh;
  fresh.internalFree = 81234;
  fresh.internalMinFree = 63012;
  fresh.dmaFree = 40112;
  fresh.dmaMinFree = 21004;
  fresh.dmaLargestBlock = 16384;
  if (memLineParses(fresh, 192) != 0) return 1;
  char line[192];
  memreport::formatLine(line, sizeof(line), fresh);
  CHECK(strstr(line, " rpcage=-1 ") != nullptr);
  CHECK(strstr(line, " afail=0 ") != nullptr);
  CHECK(strncmp(line, "mem ifree=81234 imin=63012 ", 27) == 0);

  // Every field at its widest still fits the firmware's 192-byte buffer.
  memreport::Sample widest;
  widest.internalFree = widest.internalMinFree = widest.dmaFree = 0xFFFFFFFFu;
  widest.dmaMinFree = widest.dmaLargestBlock = widest.allocFailures = 0xFFFFFFFFu;
  widest.lastFailedSize = widest.lastFailedCaps = 0xFFFFFFFFu;
  widest.rpcAgeMs = -2147483647 - 1;
  widest.uplinkErrors = 0xFFFFFFFFu;
  if (memLineParses(widest, 192) != 0) return 1;

  // A P4 with a live hosted link and a failed DMA allocation.
  memreport::Sample p4 = fresh;
  p4.allocFailures = 3;
  p4.lastFailedSize = 1664;
  p4.lastFailedCaps = 0x80C;  // DMA | 8BIT | INTERNAL
  p4.rpcAgeMs = 512;
  p4.uplinkErrors = 7;
  if (memLineParses(p4, 192) != 0) return 1;
  memreport::formatLine(line, sizeof(line), p4);
  CHECK(strstr(line, " afcaps=0x80c ") != nullptr);
  CHECK(strstr(line, " rpcage=512 ") != nullptr);

  printf("test_mem_report: %d checks passed\n", checks);
  return 0;
}
