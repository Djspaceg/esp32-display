import SenderCore

// Everything lives in the SenderCore library so a test target can import it;
// an executable target cannot be imported. This file is deliberately the only
// thing that is not testable.
ESPDisplaySenderApp.run()
