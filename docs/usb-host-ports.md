# Can these boards host a USB keyboard, and can they power it?

Settled from the vendor schematics and the vendor BSP. Nothing was measured on
hardware and no board was opened, plugged or unplugged. Where a claim would need
a meter, that is said.

## Answer in one table

| Board | Host-capable connector | Supplies 5 V to the device? | Costs the computer link? |
|---|---|---|---|
| P4 4B | H2, the second Type-C (nets USBD_P/USBD_N) | **No** | No (CH343P UART bridge is on H1) |
| P4 4C | J3, a USB type A receptacle | **Yes**, whenever the board is powered | No (CH343P on the Type-C UART port) |
| P4 3.4C | same as the 4C (shared XC schematic) | **Yes**, whenever the board is powered | No |
| S3 0.85, 1.54, 1.9, 1.85C, 1.75C, Elecrow knob | the single USB-C / MX1.25, which is also the power and flash port | **No** | **Yes** - it is the only link |
| S3 1.3 | none: the connector's data pins go to a CH343P, and GPIO19/20 are spent on reset control and the backlight | No | n/a |

So: the 4C and 3.4C can host and power a keyboard outright. The 4B can host one
but the keyboard must bring its own power. No S3 board is usable.

## P4 4B

Schematic: https://files.waveshare.com/wiki/ESP32-P4-WIFI6-Touch-LCD-4B/ESP32-P4-WIFI6-Touch-LCD-4B.pdf (page 1)

- Two Type-C receptacles. **H1 "Type-C UART"**: A6/B6 and A7/B7 carry
  USB_DBG_D_P / USB_DBG_D_N into U5, a CH343P, whose TXD/RXD reach the P4's UART.
  This is the connector the computer talks to. **H2 "Type-C"**: A6/B6 and A7/B7
  carry USBD_P / USBD_N, which go to the ESP32-P4NRW32's package pins 49 (DM) and
  50 (DP) - the dedicated USB 2.0 high-speed OTG pads. (Pin 51 is VCCA, pin 52
  GPIO24; read off the symbol's own pin list.) H2 is therefore the host port -
  the assembly drawing silkscreens it "USB-OTG" - and using it costs nothing,
  because the console lives on H1.
- The chip's other USB (USB1P1_P / USB1P1_N on GPIO25 / GPIO24, the full-speed
  serial-JTAG controller) reaches no connector: R106/R107 are marked NC/0R into
  USB_IN1_P / USB_IN1_N on the P2 expansion header.
- **VBUS is an input on both ports.** Each has 5.1 K pulldowns on CC1 and CC2
  (R1/R4 on H1, R2/R3 on H2), which is a permanent sink (UFP) advertisement -
  there is no Rp option, no CC controller and no VBUS switch. Each port's
  USB0_5V / USB1_5V reaches the board only through an AO3401 P-FET (Q2, Q3) in an
  ideal-diode OR. What holds the FET off for the unpowered port is its gate
  circuit - an MMDT3906DW pair (U3, U4) with 51K and 10K resistors referencing
  VCC_5V - and the FET symbol's body diode points from the port into VCC_5V, so
  VCC_5V is not pushed back out onto that port's VBUS either way. There is no
  boost converter, no load switch, and no VBUS enable GPIO anywhere on the
  sheet.
- The vendor BSP agrees: `bsp_usb_host_power_mode_t` has exactly one value,
  `BSP_USB_HOST_POWER_MODE_USB_DEV` ("Power from USB DEV port"), both the mode
  and `limit_500mA` are documented "Not used on this board", and
  `bsp_usb_host_start()` only installs the USB host library and starts a task -
  it touches no pin.
  https://github.com/waveshareteam/Waveshare-ESP32-components/blob/30d0ac3b8b6b27ebd402c5852819cbe0dab92749/bsp/esp32_p4_wifi6_touch_lcd_4b/esp32_p4_wifi6_touch_lcd_4b.c#L884-L901
- **Conclusion: a 4B cannot power a keyboard.** It needs a powered hub, a
  self-powered keyboard, or a cable that injects 5 V on the H2 VBUS contact.
  Injected 5 V is harmless: it is exactly what Q3 and the charger input expect.
- Residual doubt, needing a meter: the ideal-diode direction is read from the
  AO3401 symbol and the circuit's purpose, not measured. A diode test from H2's
  VBUS contact to VCC_5V (expect a Schottky-like drop one way, open the other),
  or simply powering the board through H1 and reading H2's VBUS pin (expect
  ~0 V), would settle it. The firmware does not depend on the answer: it says
  plainly that this board supplies no 5 V, and a self-powered device works
  either way.

## P4 4C and 3.4C

Schematic (shared, which both wiki pages link): https://files.waveshare.com/wiki/ESP32-P4-WIFI6-Touch-LCD-XC/ESP32-P4-WIFI6-Touch-LCD-XC-Schematic.pdf (page 1)

- Three USB connectors, one more than the 4B has. **H5 "Type-C UART"** carries
  USB_DBG_D_P/N into the CH343P (U5) - the computer link. **H1 "Type-C USB"**
  carries USB1P1_N / USB1P1_P, the full-speed serial-JTAG pair (GPIO24/GPIO25),
  through populated 0R links; on the 4B that same pair only reaches a header,
  and through R106/R107, both unpopulated. **J3, a USB type A receptacle** in
  the block titled "USB-OTG", carries VBUS_OUT on pin 1 and USBD_N / USBD_P on
  pins 2/3 - again the high-speed OTG pads. J3 is the host port.
- **VBUS_OUT is driven by the board.** U10 is a DIO7003HEST5 power-distribution
  load switch: pin 5 IN on VCC_5V, pin 1 OUT on VBUS_OUT with two 100 uF bulk
  caps, pin 3 FLG#. Its EN/EN# (pin 4) is pulled to VCC_5V through R12 (10 K)
  with R53, the pulldown, marked NC. So the switch is enabled whenever VCC_5V is
  present and no firmware control exists or is needed. VCC_5V itself is the
  OR of the two Type-C ports' 5 V through Q2/Q3 (AO3401), which is what the
  BSP's "Power from USB DEV port" wording describes: the keyboard's 5 V
  ultimately comes from whichever Type-C the board is powered through.
- **Conclusion: these two host and power a keyboard with no extra hardware**, as
  long as the board itself is powered through one of its Type-C ports (which it
  must be to run at all). The board switches that 5 V rather than generating it,
  so the current a device can draw is bounded by whatever the upstream port
  supplies, minus the board's own draw.
- Both boards' descriptors say `serial.transport = "uart_bridge"`, `bridge =
  "ch343"`, matching H5. Neither was checked on hardware; the 3.4C differs from
  the 4C only in panel.

## S3 boards

Researched separately against each board's schematic; full report in the
S3-USB-HOST.md capture. The shape is the same on all of them:

- The ESP32-S3 multiplexes USB-Serial-JTAG and USB-OTG onto one D-/D+ pair
  (GPIO19 / GPIO20), and on every S3 board here that pair goes to the single
  USB-C (or MX1.25, on the Elecrow) the board is powered, flashed and logged
  through. Switching to host tears the console down. A UART escape hatch exists
  on each board's pads or header, and holding BOOT through a reset returns the
  PHY to the ROM loader, so re-flashing is never lost - but the runtime console
  is.
- None can source 5 V. VBUS enters through a Schottky (MBR230LSFT1G: D4 on the
  0.85 and 1.54, D1 on the 1.9 and 1.85C) or straight into the AXP2101's VBUS
  input pin 37 (1.75C, whose datasheet has no boost or OTG register at all).
  Every switching part on these boards is a buck (TMI3112H, MP1605GTF-Z,
  RY3420/HX3406) or a charger (ETA6098, PL4054, AXP2101). The battery rail is
  raw cell voltage, 3.0-4.2 V. The Elecrow's GPIO2-gated OUT_5V is re-exported
  host power, not generated.
- The **S3 1.3 cannot host at all**: its Type-C data pins land on U5, a CH343P,
  and the SoC's GPIO19 / GPIO20 are used for reset control and BL_PWM. (The
  firmware already knows those pins are dangerous there - see the comment in
  firmware/rescue/rescue_model.h.)

So USB input is off on every S3 variant. Enabling it would trade the console for
an unpowered port.

## What was not read

- The XC schematic PDF carries no embedded netlist layer, so every XC claim here
  (U10, R12, R53, J3's pinout, H1's links) is a read of the rendered drawing.
  The 4B PDF does carry one, so the 4B claims are settled exactly.
- That the 4C and the 3.4C share the XC schematic is taken from the XC file's
  own title block plus both board descriptors' comments; the per-board PDF URLs
  named after each board 404.
- R53's absence and R2/R3's presence are BOM conventions on a drawing. Whether a
  shipped board matches needs a resistance check on the real thing.
- That the DIO7003's EN pin is active-high on the HEST5 variant comes from the
  schematic drawing it as pulled up with its pulldown unpopulated, not from the
  Dioo datasheet.
- On the 4B, the sink-only CC strapping was read for H2. H1 is a sink by
  construction - it feeds a CH343P - but its own CC resistors were not read
  separately.
- The 0.85 and 1.54 PDFs carry no netlist layer either; their wiring was read
  from the rendered sheet, where the parts and designators are legible and
  identical between the two.
- Only the V2 schematic of the 1.85C was examined, the one its descriptor pins
  itself to. V1 is a different PCB.
- No vendor documentation for any S3 board claims OTG host or 5 V output.
  Absence of a claim is weak evidence on its own; the Schottkys and the missing
  boost are the real evidence.
