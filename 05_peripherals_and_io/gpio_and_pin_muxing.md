# GPIO and Pin Muxing

## Overview

General-Purpose Input/Output (GPIO) is the most fundamental peripheral in any SoC. It bridges the digital logic world to the physical world via programmable I/O pads. Because a modern SoC has far more possible peripheral functions than available package pins, every production design relies on pin multiplexing (pin muxing) — hardware that connects one of several internal signals to each physical pad. Understanding GPIO controller microarchitecture, the IOPad cell structure, and the pin mux control scheme is essential for SoC peripheral integration interviews.

---

## Fundamentals

### What is a GPIO controller and what registers does it expose to software?

**Answer:**

A GPIO controller manages a bank of bidirectional I/O pads, typically 8, 16, or 32 per bank. Each pin in the bank is independently configurable. The minimal register set exposed via APB or AHB:

```
Offset  Register     Width   Description
------  -----------  -----   -----------
0x00    DATA_OUT     32-bit  Drive value for each output pin [31:0]
0x04    DATA_IN      32-bit  Sampled input value for each pin (read-only)
0x08    DIR          32-bit  Direction: 0=input, 1=output, per pin
0x0C    INTR_EN      32-bit  Enable interrupt from each input pin
0x10    INTR_STAT    32-bit  Latched interrupt status, W1C
0x14    INTR_TYPE    32-bit  0=level, 1=edge triggered, per pin
0x18    INTR_POL     32-bit  0=low/falling, 1=high/rising, per pin
0x1C    PULL_EN      32-bit  Enable pull resistor, per pin
0x20    PULL_DIR     32-bit  0=pull-down, 1=pull-up, per pin
0x24    DS_SEL       32-bit  Drive strength: 2 bits per pin (4 levels)
0x28    OD_EN        32-bit  Open-drain enable, per pin
0x2C    SET          32-bit  Write 1 to set DATA_OUT bit (write-only)
0x30    CLR          32-bit  Write 1 to clear DATA_OUT bit (write-only)
0x34    TOGGLE       32-bit  Write 1 to toggle DATA_OUT bit (write-only)
```

**Why SET/CLR/TOGGLE registers?** The naive software approach to toggling a GPIO is a read-modify-write on DATA_OUT. This is a three-instruction sequence that is non-atomic. An interrupt that modifies a different GPIO bit in between corrupts the state. SET/CLR/TOGGLE are atomic single-write operations that eliminate this race condition — this is called "bit-banding" in ARM terminology.

**Design note:** On high-pin-count SoCs, GPIO banks are replicated. A BASEADDR + 0x1000 stride per bank is a common convention. The interrupt controller typically has one interrupt line per bank, and the bank-level INTR_STAT register identifies the specific pin.

---

### What is the structure of an IOPad cell?

**Answer:**

The IOPad cell (also called an I/O buffer or I/O ring cell) is the interface between the on-chip digital logic and the package pin. A full-featured IOPad contains:

```
                    ┌─────────────────────────────────┐
                    │           IOPad Cell             │
  pkg_pin ─────────┤ Input buffer ─────────> pad_in   │
                    │                                   │
  pkg_pin <─────────┤ Output buffer <──────── pad_out  │
                    │       ^                           │
                    │       | oe (output enable)        │
                    │                                   │
                    │ Pull-up   resistor (~50-100 kΩ)  │
                    │ Pull-down resistor (~50-100 kΩ)  │
                    │ Drive strength selection (2 bits) │
                    │ Slew rate control (1-2 bits)      │
                    │ Schmitt trigger enable            │
                    │ Keeper cell (weak latch)          │
                    │ ESD protection diodes             │
                    └─────────────────────────────────┘
```

- **Input buffer:** Converts the external signal (which may be at 1.8V, 2.5V, or 3.3V) to the core logic voltage. Level-shifting is performed here. Always live unless the pad is in high-impedance.
- **Output buffer:** Drives the pin with programmable current. Output enable (OE) controls tristate: when OE=0, the output driver is disconnected and the pin is an input.
- **Pull-up/pull-down:** Weak pull resistors (typically 50-100 kΩ). Essential for input pins to prevent floating. Can be software-enabled or hard-wired. Both pull-up and pull-down simultaneously creates a potential divider — typically only one is enabled at a time.
- **Drive strength:** Typically 4 levels (2, 4, 8, 12 mA), controlled by enabling parallel output driver segments. Higher drive strength = faster slew rate = higher EMI. Best practice: use the minimum drive strength that meets timing.
- **Slew rate control:** Limits the dV/dt of the output independently of drive strength. A slow slew rate reduces overshoot and EMI at the cost of timing margin.
- **Schmitt trigger:** Adds hysteresis to the input comparator. Cleans up slow or noisy signals (e.g., mechanical switch inputs) but adds propagation delay.
- **Keeper cell:** A very weak latch that holds the last driven value. Prevents floating when the driver is tristated, without the static current of a full pull-up or pull-down. Common in bus I/O pads.
- **ESD protection:** Diode clamps to VDD and VSS. Mandatory for reliability — not a design option.

---

## GPIO Modes

### What are the output modes available on a GPIO pin, and when is each used?

**Answer:**

**Push-pull (totem-pole):** Both the pull-up (PMOS) and pull-down (NMOS) transistors are actively driven. The pin is driven aggressively to VDD or GND. This is the standard output mode and gives the fastest switching. Used for: SCLK output, general digital signals, LEDs via a buffer.

**Open-drain:** Only the pull-down (NMOS) is actively driven. The pull-up is disabled. The pin can be pulled LOW by the driver but can only reach HIGH by the external pull-up resistor. Used for:
- I2C SDA and SCL lines (mandatory for the wired-AND arbitration scheme)
- Any bus that needs to be driven by multiple devices simultaneously (the lowest value wins)
- Communication between ICs at different supply voltages without level shifters (the external pull-up is at the target voltage)

**Open-source (open-collector with PMOS):** Symmetric to open-drain — only the pull-up is active. Much less common.

**Weak pull + high-impedance input:** Output driver disabled, internal pull-up or pull-down enabled. Used for input pins where a defined default state is needed when nothing is driving the pin — e.g., JTAG TMS, SPI CS when de-selected.

---

## Pin Muxing

### Explain pin multiplexing architecture. How does a pin mux select between functions?

**Answer:**

A modern SoC might have 500 possible peripheral signals but only 80 package pins. Pin multiplexing allows each pin to be connected to one of several internal peripheral signals under software control.

**Two-level architecture (most common):**

```
                               ┌─── GPIO controller
          ┌──── FUNC_SEL ─────>│
          │    (4:1 mux)       ├─── UART0_TX
PAD_PAD_x ┤                    ├─── SPI0_SCLK
          │                    └─── PWM2_OUT
          │
          └──── PAD_CFG ─────> direction, pull, drive strength
               registers
```

The `FUNC_SEL` field is typically 2-4 bits wide per pin, supporting 4-16 alternate functions. The selection value is stored in a Pin Mux Control Register (PMCR).

**Three-level architecture (complex SoCs like Raspberry Pi BCM2837):**

1. **GPIO function select:** Selects input/output or one of 6 alternate functions.
2. **IOPad configuration:** Pull-up/pull-down, drive strength, hysteresis.
3. **Peripheral IP routing:** Some SoCs also have a signal mux inside the peripheral IP to allow internal signals to be re-routed.

**Register layout example (BCM-style):**

```
GPFSEL0 (GPIO 0-9): 3 bits per pin × 10 pins = 30 bits used
  [2:0]   FSEL0  - 000=Input, 001=Output, 100=Alt0, 101=Alt1...
  [5:3]   FSEL1
  ...
  [29:27] FSEL9
```

**Why 3 bits per pin?** Allows 8 possible functions: Input, Output, and ALT0-ALT5. This is sufficient for the typical pin to have 5-6 dedicated alternate functions plus GPIO.

---

### What problems arise from incorrect pin mux configuration, and how are they diagnosed?

**Answer:**

**Driving a pin in two directions simultaneously (contention):** If Function A drives the pin as output and Function B also has it as output, both drivers fight. The resulting voltage is undefined and both drivers may be destroyed by the current (tens to hundreds of mA). This is the most dangerous failure mode.

*Detection:* Infrared imaging of the chip shows a hot spot at the pad. Current consumption is anomalously high. In simulation, contention can be caught with SystemVerilog `X` propagation if the drivers are properly modelled as tristatable.

**Peripheral signal not reaching pin (misconfigured mux):** Software configures UART but the pin is still in GPIO input mode. The UART transmits but nothing appears on the physical pin. The UART IP sees TX_READY but the pin is floating.

*Detection:* Probing the physical pin shows no activity. Checking the PMCR register (via JTAG or register dump) reveals the wrong FUNC_SEL value.

**Pull resistor conflict:** A pad configured as open-drain I2C with the internal pull-down enabled — the pull-down will fight the external pull-up, clamping the bus to a mid-rail voltage. I2C cannot reach a logic HIGH. The bus appears permanently stuck.

*Detection:* Oscilloscope shows SDA/SCL sitting at ~1.2V instead of VDD. Check the PULL_DIR and PULL_EN registers.

**Floating input:** An unused input pin with no pull resistor will couple noise and oscillate at RF frequencies. This wastes power (CMOS static power scales with input voltage swings through the inverter threshold) and can cause spurious interrupts.

*Best practice:* All unused pins must be configured as outputs driving a fixed value, or as inputs with pull-up or pull-down enabled. Never leave a pin truly floating in production.

---

## IOPad Design

### How does drive strength selection work at the transistor level?

**Answer:**

The output driver is a CMOS inverter. Drive strength is increased by placing multiple identical inverters in parallel:

```
       VDD
        |
      [P1] [P2] [P4] [P8]    <- PMOS width ratio 1:2:4:8
        |    |    |    |
        +----+----+----+----> PAD
        |    |    |    |
      [N1] [N2] [N4] [N8]    <- NMOS width ratio 1:2:4:8
        |    |    |    |
       GND
      DS[0] DS[1] DS[2] DS[3]   <- enable transistor banks
```

Each transistor bank is enabled by the corresponding `DS` control bit. Enabling more banks increases the total drive current:
- `DS[0]` only: 2 mA (1× strength)
- `DS[0:1]`: 4 mA (2× strength)
- `DS[0:2]`: 8 mA (4× strength)
- `DS[0:3]`: 16 mA (8× strength)

**Slew rate relationship:** Higher drive strength = faster slew rate because more current charges the pad capacitance (I = C × dV/dt). To slow the slew rate without reducing drive current, a separate resistor can be switched into the output path, creating a deliberate RC time constant.

**Power consideration:** A CMOS output switching at frequency f with capacitance C and voltage V dissipates P = C × V² × f per switch. High drive strength increases effective C (the internal gate capacitances of the additional transistors also switch). Use the minimum drive strength that meets setup/hold timing — this directly reduces power and EMI.

---

## Best Practices

### What is a pin strapping configuration and how is it implemented safely?

**Answer:**

Pin strapping is a technique where the state of certain I/O pins at reset time is read by the boot ROM or hardware to configure the SoC's boot behaviour. Examples:
- `BOOT_SEL[1:0]`: selects boot from SPI flash, NAND, SDCARD, or JTAG
- `JTAG_EN`: enables or disables the JTAG debug interface
- `UART_BAUD`: selects 115200 or 9600 baud for the debug console

**Implementation challenges:**

1. **Metastability of strapping pins:** The boot ROM reads strap values early in the boot sequence before the system clock is stable. Strap inputs are typically sampled into a hardwired latch driven by the power-on reset pulse, not a synchronised flip-flop. The latch output is held until explicitly cleared.

2. **Contention after strapping:** After reset, the peripheral that owns the strap pin (e.g., SPI flash CS) takes over the pad. The pin mux must transition cleanly. The boot ROM ensures the peripheral is fully initialised before releasing the strap value latch.

3. **External resistor value selection:** The strap pin has an internal weak pull (say, pull-up to VDD at 100 kΩ). An external resistor of 10 kΩ is strong enough to override the internal pull while consuming only 0.33 mA. A too-weak external resistor (e.g., 1 MΩ) fails to override the internal pull; a too-strong resistor (e.g., 100 Ω) wastes current.

4. **Security implications:** Debug-enable strap pins are a security concern. Production devices are often programmed with an OTP fuse that ignores or overrides strap pin values for security-sensitive settings (JTAG disable, secure boot enable).

---

### Walk through the complete configuration sequence to bring up a UART on a GPIO-capable pin.

**Answer:**

Assume: UART0_TX is available on PAD_12 (alternate function 2), and the system is initially in reset with all pins as GPIO inputs.

```
Step 1: Configure pin mux
  Write FUNC_SEL[12] = 2  (select Alt2 = UART0_TX)
  // PAD_12 now routes UART0_TX internally; GPIO output is disconnected

Step 2: Configure pad electrical properties
  Write DIR[12]     = 1   (output, though for ALT function this may be
                            auto-overridden by the peripheral)
  Write PULL_EN[12] = 0   (disable pull — UART TX idles HIGH, no pull needed)
  Write OD_EN[12]   = 0   (push-pull, not open-drain)
  Write DS_SEL[12]  = 1   (4 mA drive strength, sufficient for typical PCB trace)

Step 3: Configure UART peripheral
  Write UART0_BAUD_DIV  = (f_pclk / (16 × baud_rate)) - 1
  Write UART0_LCR       = 0x03  (8N1: 8 data bits, no parity, 1 stop)
  Write UART0_FCR       = 0x07  (enable and clear TX and RX FIFOs)
  Write UART0_IER       = 0x02  (TX FIFO empty interrupt)
  Write UART0_CTRL      = 0x01  (enable UART)

Step 4: Enable UART interrupt at NVIC/PLIC
  NVIC_EnableIRQ(UART0_IRQn)

Step 5: Verify
  Probe PAD_12 — should idle HIGH
  Write 0x55 to UART0_THR — oscilloscope should show 0x55 frame
```

**Common mistake:** Steps 1 and 2 must occur before Step 3. If the peripheral is enabled before the pin mux is set, the first few bits may be missed or corrupted because the signal is not yet connected to the pad. Some SoC boot ROMs configure pin mux in a dedicated early-boot phase before enabling any peripherals.
