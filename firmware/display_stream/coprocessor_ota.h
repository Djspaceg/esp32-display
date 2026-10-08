// The CFGC6UPDATE transfer, on its own task: every step is an ESP-Hosted RPC
// or a network wait, and loopTask must never wait on either. Only
// coprocessor_service.cpp calls this, after its own checks; P4 family only.
#pragma once

#include <stdint.h>

#include "coprocessor_update.h"

namespace coprocessorota {

/// Starts the update task and returns nullptr, or returns why not. The task
/// asks the coprocessor its version once more and refuses unless it is still
/// older than `hostVersion`, then downloads `image`, streams it through
/// coprocessor::runTransfer, and restarts the board once it is installed.
const char *start(const coprocessor::Image &image, uint32_t hostVersion);

bool running();

}  // namespace coprocessorota
