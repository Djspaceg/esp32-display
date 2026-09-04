// SPI/QSPI backend compatibility surface.
// The established implementation remains in panel_init.h so existing sketches
// keep their include path; display_backend.h selects it only for SPI/QSPI.
#pragma once
#include "panel_init.h"
namespace boardpanelspi = boardpanel;
