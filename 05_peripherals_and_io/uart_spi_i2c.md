# UART, SPI, and I2C

## Overview

UART, SPI, and I2C are the three serial communication protocols most commonly encountered in SoC peripheral subsystems. Each originated from a distinct design philosophy — UART optimises for simplicity and point-to-point range, SPI for throughput, and I2C for minimising pin count while supporting multiple devices on a shared bus. Understanding their frame formats, electrical characteristics, and failure modes is essential for both SoC design and system integration interviews.

---

## Fundamentals

### What are the key differences between UART, SPI, and I2C?

**Answer:**

| Property          | UART                    | SPI                         | I2C                          |
|-------------------|-------------------------|-----------------------------|------------------------------|
| Topology          | Point-to-point          | Single master, multi-slave  | Multi-master, multi-slave    |
| Wires (min)       | 2 (TX, RX)              | 4 (SCLK, MOSI, MISO, CS)   | 2 (SDA, SCL)                 |
| Clock             | None (async, baud rate) | Synchronous (master-driven) | Synchronous (master-driven)  |
| Typical speed     | Up to ~5 Mbit/s         | Up to ~100 Mbit/s           | 100 kbit/s / 1 Mbit/s / 3.4 Mbit/s |
| Addressing        | None (physical wires)   | Chip select line per slave  | 7-bit or 10-bit address byte |
| Duplex            | Full duplex              | Full duplex                 | Half duplex                  |
| Drive             | Push-pull                | Push-pull                   | Open-drain, requires pull-up |
| Error detection   | Parity bit (optional)   | None (protocol-level)       | ACK/NACK per byte            |

The underlying reason for these differences: UART was designed for asynchronous terminal communication (1960s RS-232); SPI was designed by Motorola for short-range, high-bandwidth chip-to-chip links; I2C was designed by Philips to wire multiple cheap ICs together using only the power-rail wires.

---

## UART Protocol

### Describe the UART frame format and explain the purpose of each field.

**Answer:**

A standard UART frame transmitted LSB-first at a configured baud rate:

```
 Idle  Start  D0  D1  D2  D3  D4  D5  D6  D7  Parity  Stop
  _____|_   |___|___|___|___|___|___|___|___|___|_____|______
       | \  |                                           |
       |  \_|  <- Start bit is always a SPACE (logic 0) |
       |                                                |
       +-- Line idles MARK (logic 1) -------------------+
```

- **Idle state**: Line held HIGH (MARK). This allows the receiver to detect a disconnected or broken transmitter (line would float, not stay high).
- **Start bit**: Always logic 0 (SPACE), exactly 1 bit period. The falling edge is the synchronisation event — the receiver samples data bits at 1.5 bit periods after the start bit's leading edge, then every 1 bit period after.
- **Data bits**: 5 to 9 bits, configurable. LSB transmitted first. 8N1 (8 data, no parity, 1 stop) is by far the most common configuration.
- **Parity bit** (optional): Even parity means the total number of 1s including the parity bit is even. Odd parity makes the total odd. Mark parity is always 1; space parity is always 0. Can detect single-bit errors, not two-bit errors.
- **Stop bit(s)**: 1, 1.5, or 2 bit periods of MARK (logic 1). Allows the receiver to re-arm for the next start bit and gives legacy slow devices processing time.

**Common interview mistake**: Candidates confuse the idle polarity. The line idles HIGH. The start bit is LOW. In RS-232 the voltage levels are inverted (logic 1 is negative voltage), but within a UART IP block the convention is logic-level high = MARK.

**Baud rate mismatch**: If transmitter and receiver baud rates differ by more than roughly 3.5%, the receiver samples the last data bit outside the valid eye. The 1.5-bit sampling offset for the first bit gives tolerance, but error accumulates. This is why UART baud rates use exact integer divisors of the reference clock.

---

### How does a UART receiver clock-recover and sample data without a clock signal?

**Answer:**

The receiver runs an internal oversampling clock, typically 16x the baud rate:

1. Receiver monitors the idle HIGH line continuously.
2. A falling edge on RX triggers a start-bit detector.
3. The receiver waits 8 oversampling clocks (half a bit period) to reach the centre of the start bit, then verifies it is still LOW. If it has returned HIGH, the falling edge was a glitch and is discarded.
4. The receiver waits a further 16 oversampling clocks (one full bit period) to sample D0 at its centre, then D1, and so on.
5. At the stop bit position, the receiver checks for a HIGH. A LOW at this point is a **framing error** — the byte is discarded and a status flag is set.

The 16x oversampling means a baud rate of 115200 requires a 1.8432 MHz oversampling clock. Real implementations often use a 16x fractional divider to allow a wide range of baud rates from a fixed reference.

---

## SPI Protocol

### Explain SPI CPOL and CPHA and draw the four mode waveforms.

**Answer:**

SPI has two configuration bits that together define four operating modes:

- **CPOL (Clock Polarity)**: defines the idle state of SCLK.
  - CPOL=0: clock idles LOW
  - CPOL=1: clock idles HIGH

- **CPHA (Clock Phase)**: defines which clock edge is used to sample (latch) data.
  - CPHA=0: data is sampled on the **first** clock edge after CS goes active
  - CPHA=1: data is sampled on the **second** clock edge after CS goes active

```
Mode 0 (CPOL=0, CPHA=0): idle low, sample on rising edge
  CS   _____|_________________________________|___
  SCLK ________|--|__|--|__|--|__|--|__|--|__|______
  MOSI ________X---D7---X---D6---X---...---X------
                ^   ^   ^   ^   ^
                sample edges (rising)

Mode 1 (CPOL=0, CPHA=1): idle low, sample on falling edge
  CS   _____|_________________________________|___
  SCLK ________|--|__|--|__|--|__|--|__|--|__|______
  MOSI _____________X---D7---X---D6---X---...-----
                     ^   ^   ^   ^
                     sample edges (falling)

Mode 2 (CPOL=1, CPHA=0): idle high, sample on falling edge
  CS   _____|_________________________________|___
  SCLK ______|--|__|--|__|--|__|--|__|--|__|--|____
  MOSI ________X---D7---X---D6---X---...---X------
                ^   ^   ^   ^   ^
                sample edges (falling, first edge)

Mode 3 (CPOL=1, CPHA=1): idle high, sample on rising edge
  CS   _____|_________________________________|___
  SCLK ______|--|__|--|__|--|__|--|__|--|__|--|____
  MOSI _____________X---D7---X---D6---X---...-----
                     ^   ^   ^   ^
                     sample edges (rising)
```

**Practical significance**: A master must match the slave's mode exactly. Mode 0 and Mode 3 sample on the same relative edge (the edge that leads from idle to active); Mode 1 and Mode 2 are the alternate. The most common modes are Mode 0 and Mode 3. When bringing up a new device, the datasheet will specify one of these four modes; a mismatch causes every bit to be shifted by half a clock and all bytes will be corrupted.

**Common mistake**: Candidates confuse which edge is "first". With CPOL=0 and an active-low CS, the first edge after CS asserts is a rising edge (CPHA=0 samples here). With CPOL=1, the first edge is a falling edge.

---

### How does SPI handle multiple slaves, and what are the limitations?

**Answer:**

**Independent CS lines (standard):** Each slave gets its own dedicated chip-select. The master asserts exactly one CS low, clocks the transaction, then deasserts. Slaves not selected ignore SCLK and leave MISO in high-impedance. This is simple and reliable but requires N GPIO pins for N slaves, scaling poorly.

**Daisy-chain (shift-register mode):** MOSI of the master feeds SDI of slave 1; SDO of slave 1 feeds SDI of slave 2; SDO of the last slave feeds MISO of the master. All slaves share a single CS. The master clocks N×8 bits to shift data through the entire chain. Each slave captures its own byte as it passes through. This reduces pin count but means a single byte update requires writing all slaves simultaneously — common in LED driver chains (e.g., WS2801, SPI-addressable shift registers).

**Limitations:**
- No acknowledgment mechanism — there is no way for a slave to indicate it received data correctly
- No addressing within a transaction; selection is entirely physical (CS line)
- MISO is shared; only one slave may drive it at any time, so the master must ensure only one CS is asserted
- Maximum bus length is limited by parasitic capacitance; SPI is not designed for long wires

---

## I2C Protocol

### Describe the I2C frame format including the START condition, address phase, and ACK/NACK.

**Answer:**

I2C uses two open-drain lines: **SDA** (data) and **SCL** (clock). Both lines idle HIGH through pull-up resistors. Only a master can initiate a transaction.

**START condition:** A HIGH-to-LOW transition on SDA **while SCL is HIGH**. This is illegal during normal data transfer (SDA may only change while SCL is LOW), so it is unambiguous as a control symbol.

**STOP condition:** A LOW-to-HIGH transition on SDA **while SCL is HIGH**.

**Standard write transaction (7-bit addressing):**

```
START | ADDR[6:0] | W(0) | ACK | DATA[7:0] | ACK | ... | STOP
       <-- 8 bits clock -->  ^    <-- 8 bits --->  ^
                             |                     |
                      slave pulls SDA low    slave pulls SDA low
```

- **Address byte**: 7-bit address MSB-first, followed by R/W bit (0=write, 1=read).
- **ACK**: After the 9th clock pulse, the addressed slave releases SDA to HIGH-Z during bits 0-7, then on the 9th clock it pulls SDA LOW to acknowledge. The master must sample SDA during the 9th SCL HIGH period.
- **NACK**: If SDA remains HIGH at the 9th clock, no slave responded (address not found) or the slave is signalling it cannot accept more data (e.g., internal buffer full).

**Repeated START:** The master issues a START condition without a preceding STOP. This allows the master to change direction (write address then read data) without releasing the bus, preventing another master from seizing it between the two phases. Essential for register-addressed reads.

**Standard read transaction:**

```
START | ADDR | W | ACK | REG_ADDR | ACK | RESTART | ADDR | R | ACK | DATA | NACK | STOP
```

The NACK before STOP is intentional — it signals to the slave that the master does not want more bytes (I2C slaves auto-increment their internal pointer and would keep sending if ACKed).

---

### Explain I2C multi-master arbitration and clock stretching.

**Answer:**

**Multi-master arbitration:** I2C supports multiple masters on the same bus without a central arbiter. Arbitration is wired-AND and is lossless:

1. Both masters observe the bus idle (SDA and SCL both HIGH).
2. Both generate a START and begin transmitting their address bytes simultaneously.
3. After each bit, each master compares what it drove with what it sees on SDA. Because SDA is open-drain, if Master A drives HIGH but Master B drives LOW, the bus reads LOW (low wins in wired-AND).
4. Master A sees a discrepancy — it drove HIGH but reads LOW — and immediately stops transmitting and surrenders the bus.
5. Master B never observes a discrepancy (it was already driving LOW) and continues its transaction uninterrupted.

**Why it is lossless:** The winning master's transaction proceeds exactly as if the losing master had never tried. No data corruption occurs. The losing master retries after detecting a STOP condition.

**Clock stretching:** A slave may hold SCL LOW after the master releases it. The master monitors SCL and waits for it to go HIGH before it can proceed. This allows slow slaves (e.g., a sensor performing a measurement) to throttle the master without missing bytes. The master must never time out too aggressively or it will misinterpret stretching as a bus fault.

**Common design problem:** An I2C bus can be permanently locked if a slave is mid-transfer during a reset (SDA stuck low, slave waiting for clocks). The standard recovery procedure is for the master to clock SCL 9 times, which forces the slave out of its data byte and allows it to emit a NACK, after which the master issues a STOP.

---

## Intermediate

### Compare I2C pull-up resistor selection: what are the tradeoffs?

**Answer:**

I2C lines are open-drain. Pull-up resistors set the rising edge slew rate and thus the maximum achievable clock rate.

**Small resistor (e.g., 1 kΩ):**
- Fast rising edges — supports high clock rates
- High current when a device pulls the line low: V_DD / R = 3.3V / 1kΩ = 3.3 mA per line. With multiple masters and slaves the total current is significant.
- The combined capacitance of all devices and PCB traces still limits rise time: t_rise = 0.8473 × R × C

**Large resistor (e.g., 10 kΩ):**
- Low power — line current is only 0.33 mA
- Slow rising edges: with C_bus = 100 pF, time constant = 10kΩ × 100pF = 1 µs. At 400 kHz (Fast mode), the maximum rise time is 300 ns. A 10 kΩ pull-up violates this.

**Selection rule of thumb:**
- Standard mode (100 kHz): up to ~10 kΩ acceptable
- Fast mode (400 kHz): 2-4 kΩ typical
- Fast-mode Plus (1 MHz): 1 kΩ or active pull-ups
- High-speed mode (3.4 MHz): requires active current-source pull-ups

The I2C specification defines maximum bus capacitance as 400 pF. Active pull-ups (switched current sources that supply high current on the rising edge, then reduce to maintain HIGH level) are used in demanding designs.

---

### A UART receives 0xA5 but the transmitter sent 0xAA. What has gone wrong?

**Answer:**

0xAA in binary is 10101010. 0xA5 is 10100101.

Comparing LSB-first transmission:
- Transmitted bits: 0, 1, 0, 1, 0, 1, 0, 1 (LSB first = 0xAA)
- Received bits:    1, 0, 1, 0, 0, 1, 0, 1 (= 0xA5)

The first three bits are inverted. This is consistent with a **baud rate error** where the receiver's sampling clock is fast enough that by bit 2-3 it has drifted half a bit period and is sampling on the wrong side of each transition.

Alternatively, if **all bits were individually inverted** (MARK/SPACE polarity inversion), 0xAA (10101010) inverted becomes 01010101 = 0x55, not 0xA5. So polarity inversion alone doesn't fit.

The most likely cause given the specific pattern: a **3.5%+ baud rate mismatch**. With 16x oversampling, each bit period is 16 samples. A 3.5% error means the receiver is 0.56 samples off per bit. By bit 8, it is 4.5 samples off — right at the edge of the valid sampling window. The high-frequency alternating pattern of 0xAA maximally stresses this.

**How to debug:** Check the actual measured baud rate with an oscilloscope. Verify that both sides use the same reference clock frequency, that the clock divider register is set correctly, and that no fractional baud rate setting has been applied.

---

## Advanced

### Design a register map for an SPI master peripheral with FIFO support. Describe each register and its fields.

**Answer:**

A minimal but production-representative SPI master register map (APB-accessible):

```
Offset  Register    Fields
------  ---------   ------
0x00    CTRL        [31:16] Reserved
                    [15:8]  CLK_DIV[7:0]   - SCLK = f_pclk / (2 × (CLK_DIV + 1))
                    [7]     CPOL           - Clock polarity
                    [6]     CPHA           - Clock phase
                    [5:4]   FRAME_SZ[1:0]  - 00=8b, 01=16b, 10=24b, 11=32b
                    [3:2]   CS_SEL[1:0]    - Which chip select to assert (0-3)
                    [1]     LSB_FIRST      - 0=MSB first, 1=LSB first
                    [0]     ENABLE         - Block enable

0x04    STATUS      [31:8]  Reserved
                    [7]     TX_FULL        - TX FIFO full (read-only)
                    [6]     TX_EMPTY       - TX FIFO empty (read-only)
                    [5]     RX_FULL        - RX FIFO full (read-only)
                    [4]     RX_EMPTY       - RX FIFO empty (read-only)
                    [3]     BUSY           - Transaction in progress (read-only)
                    [2]     RX_OVERFLOW    - Write 1 to clear
                    [1]     TX_UNDERRUN    - Write 1 to clear
                    [0]     COMPLETE       - Write 1 to clear

0x08    TX_DATA     [31:0]  Data to push into TX FIFO (write-only)

0x0C    RX_DATA     [31:0]  Data popped from RX FIFO (read-only)

0x10    INTR_EN     [3]     RX_HALF_FULL interrupt enable
                    [2]     TX_HALF_EMPTY interrupt enable
                    [1]     COMPLETE interrupt enable
                    [0]     ERROR interrupt enable

0x14    FIFO_CTRL   [15:8]  RX_THRESH[7:0] - RX FIFO threshold for interrupt
                    [7:0]   TX_THRESH[7:0] - TX FIFO threshold for interrupt

0x18    CS_TIMING   [15:8]  CS_SETUP[7:0]  - CS assert to first SCLK, in PCLK cycles
                    [7:0]   CS_HOLD[7:0]   - Last SCLK to CS deassert, in PCLK cycles
```

**Design rationale:**
- `CLK_DIV` supports a range of SCLK speeds without requiring a dedicated PLL.
- Separate TX and RX FIFOs allow the master to queue multiple transfers and service them without the CPU's involvement on every byte.
- `CS_TIMING` fields address a common hardware problem: many flash memories and ADCs require setup/hold time between CS assertion and the first clock edge. Without these fields, software must insert NOP loops — unreliable at high CPU frequencies.
- Threshold-based interrupts reduce interrupt frequency: the CPU is only interrupted when the TX FIFO needs refilling (below threshold) or the RX FIFO needs draining (above threshold), not once per byte.

---

### What is the I2C 10-bit addressing extension and when is it used?

**Answer:**

Standard 7-bit I2C allows 128 addresses; with reserved ranges, roughly 112 are usable. This is insufficient for large systems. The 10-bit extension allows 1024 addresses.

**Frame format for 10-bit write:**

```
START | 11110XX W | ACK | XXXXXXXX | ACK | DATA ... | STOP
       ^--------^         ^------^
       First address      Second address byte
       byte: upper 2      (lower 8 bits)
       bits (XX) of
       10-bit addr
```

The first byte has the reserved prefix `11110` in bits [7:3], bits [2:1] carry the upper two bits of the 10-bit address, and bit [0] is the R/W flag.

**Backward compatibility:** Standard 7-bit slaves ignore the first byte because they do not implement the `11110` prefix in their address comparator. Only slaves explicitly designed for 10-bit addressing respond.

**Repeated START with 10-bit address read:**

```
START | 11110XX W | ACK | lower8 | ACK | RESTART | 11110XX R | ACK | DATA | NACK | STOP
```

The RESTART re-sends the first address byte with R/W=1. The slave remembers the internal register pointer from the write phase.

**When used:** Large industrial systems, I2C buses shared across multiple boards, sensor networks with many nodes. In practice, the more common solution is to cascade multiple I2C segments with I2C multiplexers (e.g., TCA9548A), which avoids 10-bit addressing complexity.

---

## Comparative Analysis

### When would you choose SPI over I2C for a high-speed ADC interface?

**Answer:**

Choose SPI for a high-speed ADC for these reasons:

1. **Speed**: SPI supports clock rates into the tens or hundreds of MHz; I2C Fast-mode Plus tops out at 1 MHz and High-speed at 3.4 MHz. A 16-bit ADC at 1 MSPS requires 16 Mbit/s minimum — well within SPI but impossible with standard I2C.

2. **Full duplex**: SPI can simultaneously send the next conversion trigger command while receiving the previous sample. I2C is half-duplex.

3. **Deterministic timing**: SPI has no clock stretching. I2C clock stretching introduces non-deterministic latency, which is problematic for a real-time sample stream.

4. **No overhead**: SPI transactions begin with the first clock edge after CS asserts. I2C has a mandatory address phase (9 clocks) on every transaction — unacceptable per-sample overhead at high sample rates.

5. **Protocol complexity**: I2C ACK/arbitration logic adds latency and potential for bus lockup, which requires recovery logic. SPI has no such mechanism.

**When I2C is preferred:** Configuration registers that are written infrequently (ADC range, filter settings), where multiple control ICs share a bus. Many ADC designs use SPI for the data path and I2C for configuration — the two protocols are complementary.

---

## Design Considerations

### How do you handle metastability when routing SPI MISO through a synchroniser?

**Answer:**

SPI MISO is generated by the slave synchronously with SCLK. The master samples MISO relative to SCLK, but in an FPGA or SoC with a separate system clock (e.g., 100 MHz system clock, 10 MHz SCLK), the registered MISO sample is not synchronous to the system clock.

**Problem:** The master's shift register samples MISO on (say) the rising edge of SCLK. The system logic runs on CLK_SYS. There are two clock domains, and the registered MISO value must cross them.

**Solution — double-flop synchroniser on MISO:**

```
MISO_in --> [FF1, SCLK] --> [FF2, CLK_SYS] --> [FF3, CLK_SYS] --> shift_reg
                            ^---- metastability ^---- stable
                                  resolve time       capture
```

Actually, for an SPI master the canonical approach is:

1. The master controls SCLK, so it knows exactly when SCLK transitions occur.
2. Instead of sampling MISO directly on SCLK, the master uses a delayed SCLK (half a CLK_SYS period) to sample MISO, ensuring maximum setup time.
3. The captured MISO value is then in the CLK_SYS domain because the sample flip-flop is clocked by CLK_SYS.
4. No double-flop is needed because the setup/hold window is engineered.

The alternative (sampling on SCLK rising edge directly) does require a two-stage synchroniser if SCLK is not a clean multiple of CLK_SYS. The MTBF must be analysed — at 10 MHz SCLK and 100 MHz CLK_SYS, the metastability resolution time is 10 ns, which gives ample settling time in a standard 28 nm process (τ ≈ 30 ps).
