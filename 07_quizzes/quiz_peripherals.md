# Quiz: Peripherals and I/O

15 multiple-choice questions covering UART, SPI, I2C, GPIO, interrupt controllers, and timers. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** A UART is configured for 115200 baud, 8 data bits, 1 stop bit, and no parity. How many bits are transmitted per character, including framing?

- A) 8
- B) 9
- C) 10
- D) 11

---

**Q2.** In SPI (Serial Peripheral Interface), which signal determines the clock polarity and phase relationship between the master clock and the data lines?

- A) CS (Chip Select)
- B) MOSI and MISO direction
- C) CPOL and CPHA configuration bits
- D) The SPI clock frequency register

---

**Q3.** I2C uses a 7-bit device address. How many unique device addresses are available in standard I2C, excluding reserved addresses?

- A) 128
- B) 112
- C) 127
- D) 64

---

**Q4.** A level-triggered interrupt remains asserted until the interrupt source is cleared. An edge-triggered interrupt fires on a signal transition. Which statement describes a key risk of edge-triggered interrupts?

- A) A level-triggered interrupt cannot be shared between multiple devices on a single interrupt line
- B) If the edge transition is missed (for example, due to an interrupt being masked when the edge occurs), the interrupt will not be re-presented and the event will be lost
- C) Edge-triggered interrupts require higher CPU priority than level-triggered interrupts
- D) Edge-triggered interrupts cannot be used with DMA controllers

---

**Q5.** A free-running counter-based timer generates a periodic interrupt every N clock cycles. The system clock is 100 MHz and an interrupt is needed every 1 ms. What reload value should be programmed into the timer?

- A) 1,000
- B) 10,000
- C) 100,000
- D) 1,000,000

---

### Intermediate (Q6 -- Q11)

**Q6.** A UART receiver samples each data bit at its centre to maximise noise margin. If the receiver's internal baud clock runs at 16x the baud rate, at which sample within a bit period does the receiver latch the data bit?

- A) Sample 1 (at the start of the bit period, immediately after the start bit edge)
- B) Sample 8 (at the centre of the bit period)
- C) Sample 16 (at the end of the bit period)
- D) Samples 7, 8, and 9 with majority voting

---

**Q7.** An I2C master performs a combined write-then-read transaction to a register-based sensor. The correct sequence of I2C operations is:

- A) START, write device address + W, write register address, STOP, START, write device address + R, read data, NACK, STOP
- B) START, write device address + W, write register address, repeated START, write device address + R, read data, NACK, STOP
- C) START, write device address + W, write register address, write data, STOP
- D) START, write device address + R, read register address, read data, NACK, STOP

---

**Q8.** An SPI master must communicate with a slave device that supports SPI Mode 3 (CPOL=1, CPHA=1). Which statement correctly describes when the slave samples data?

- A) Data is sampled on the rising edge of SCLK; the clock idles low
- B) Data is sampled on the falling edge of SCLK; the clock idles high
- C) Data is sampled on the rising edge of SCLK; the clock idles high
- D) Data is sampled on the falling edge of SCLK; the clock idles low

---

**Q9.** A GPIO pin is configured as an open-drain output. The driver asserts the pin low. What happens to the pin voltage when the driver releases (de-asserts) the pin?

- A) The pin is driven to VDD by the GPIO output driver
- B) The pin floats to an undefined voltage unless an external pull-up resistor is connected
- C) The pin stays low until the next write to the GPIO direction register
- D) The pin is internally pulled to VDD by the GPIO controller's built-in pull-up

---

**Q10.** An interrupt controller implements a priority scheme with 8 levels (0 = lowest, 7 = highest). Two devices simultaneously assert interrupts: device A at priority 5 and device B at priority 3. The CPU is currently serving an interrupt from device C at priority 4. What happens?

- A) Device A preempts device C because A has higher priority; device B waits until device C completes
- B) Both A and B are queued; neither preempts device C because the CPU is already in an interrupt handler
- C) Device A preempts device C; device B is also allowed to preempt device C because priority 3 > 0
- D) The interrupt controller raises a double-fault because two interrupts arrived simultaneously

---

**Q11.** A watchdog timer is programmed to reset the system if not refreshed within 100 ms. The software refresh ("kick") routine is called from a 10 ms periodic timer interrupt. During a software deadlock, the 10 ms timer ISR stops executing. After how long does the watchdog reset the system?

- A) 10 ms -- the watchdog fires as soon as the first missed kick is detected
- B) Up to 100 ms -- the watchdog resets the system at most 100 ms after the last successful kick
- C) 1000 ms -- the watchdog requires 10 consecutive missed kicks before asserting reset
- D) Immediately -- the watchdog detects the deadlock via a software health monitor

---

### Advanced (Q12 -- Q15)

**Q12.** A SPI flash memory device requires a minimum chip-select de-assertion time (CS high time) of 50 ns between consecutive transactions to allow its internal state machine to settle. The SPI master drives CS from a GPIO and issues CS assertions in software. The processor runs at 500 MHz (2 ns per cycle). What is the minimum number of NOP instructions (or equivalent delay loops) the software must insert between de-asserting CS and re-asserting it?

- A) 1
- B) 5
- C) 25
- D) 50

---

**Q13.** An interrupt-driven UART receiver uses a receive FIFO with a depth of 16 bytes. The interrupt is configured to fire when the FIFO is half-full (8 bytes). At 115200 baud with 10 bits per character, what is the time available between the interrupt firing and the FIFO overflowing if the CPU does not service the interrupt?

- A) Approximately 69 us
- B) Approximately 694 us
- C) Approximately 6.9 ms
- D) Approximately 8 byte-times regardless of baud rate

---

**Q14.** A system uses a GIC-400 (ARM Generic Interrupt Controller) configured with 4 CPU interfaces and 128 Shared Peripheral Interrupts (SPIs). An SPI must be routed to all four CPUs for load-balancing. Which GIC register mechanism enables this?

- A) The GICD_ITARGETSR register, which accepts a CPU affinity mask for each SPI
- B) The GICD_IGROUPR register, which places the interrupt in Group 1 for broadcast delivery
- C) The GICD_NSACR register, which grants non-secure access to all CPUs simultaneously
- D) SPIs cannot be routed to multiple CPUs; only SGIs (Software Generated Interrupts) support multi-CPU targeting

---

**Q15.** An I2C bus is operating at 400 kHz (Fast Mode). The master is reset in the middle of a read, while a slave is driving a 0 data bit on SDA. When the master restarts, it finds SCL high but SDA held low indefinitely, so it cannot generate a START. What is this condition and what is the standard recovery?

- A) A repeated START condition; the master should continue the previous transaction
- B) Clock stretching by the slave; the master should simply wait for the slave to release the bus
- C) Bus lockup: the slave is stuck mid-byte holding SDA low; the master should clock SCL up to nine times until the slave releases SDA, then generate a STOP
- D) Arbitration loss; the master should back off and retry after the bus-free time



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | C      |
| 2  | C      |
| 3  | B      |
| 4  | B      |
| 5  | C      |
| 6  | D      |
| 7  | B      |
| 8  | C      |
| 9  | B      |
| 10 | A      |
| 11 | B      |
| 12 | C      |
| 13 | B      |
| 14 | A      |
| 15 | C      |

---

## Detailed Explanations

**Q1 -- Answer: C**

A UART frame consists of: 1 start bit + 8 data bits + 1 stop bit = 10 bits total. The start bit is always present and signals the beginning of a character. The stop bit signals the end. If a second stop bit were used, the count would be 11. With parity enabled, a parity bit is inserted between the data bits and stop bit, making 11 bits. No parity, 1 stop bit: 1 + 8 + 1 = 10 bits. Option A omits framing. Option B omits the stop bit. Option D would apply to 8N2 (8 data, no parity, 2 stop bits).

---

**Q2 -- Answer: C**

CPOL (Clock Polarity) defines the idle state of SCLK: CPOL=0 idles low, CPOL=1 idles high. CPHA (Clock Phase) defines whether data is sampled on the first or second clock edge: CPHA=0 samples on the leading edge, CPHA=1 samples on the trailing edge. These two bits produce the four SPI modes (0 through 3). Chip Select (CS) controls device selection, not timing. MOSI/MISO direction is fixed (master out/slave in and master in/slave out). The clock frequency register sets speed, not timing phase.

---

**Q3 -- Answer: B**

The I2C specification defines a 7-bit address space of 128 total addresses (0x00 to 0x7F). However, 16 addresses are reserved: the 8 addresses of the form 0000_xxx (general call, CBUS, reserved) and the 8 addresses 1111_xxx (10-bit addressing extension, reserved for future). This leaves 128 - 16 = 112 usable device addresses. Option A (128) ignores the reserved addresses. Option C (127) removes only one reserved address. Option D (64) incorrectly halves the space.

---

**Q4 -- Answer: B**

Edge-triggered interrupts respond to a transition (rising or falling edge) rather than a sustained level. If the interrupt source generates an edge while the interrupt is masked (disabled), the edge occurs and is gone -- the controller will not see a sustained high level to detect later. The interrupt event is missed and the handler never executes, potentially causing a hang or data loss. Level-triggered interrupts do not have this problem: the source holds the level asserted until serviced, so even if masked temporarily, the level will be detected when unmasked. Option A describes a real limitation of level-triggered interrupts (shared lines require open-drain), but the question asks about edge-triggered risk. Options C and D are incorrect.

---

**Q5 -- Answer: C**

1 ms at 100 MHz = 100 MHz * 1e-3 s = 100,000 clock cycles. The timer must be programmed to count 100,000 cycles (or reload value of 99,999 if counting from N-1 to 0, but many timers use a reload value equal to the desired count). Option A (1,000) gives 10 us. Option B (10,000) gives 100 us. Option D (1,000,000) gives 10 ms. Always verify: cycles = frequency * period = 100e6 * 1e-3 = 1e5 = 100,000.

---

**Q6 -- Answer: D**

With a 16x oversampling baud clock, each bit period is 16 oversampling clocks wide. The start bit edge is detected at sample 1. Sampling at the centre means sample 8 would be exact centre, but sampling at a single point is sensitive to noise. Most real UART receivers use majority voting over three consecutive samples near the centre (samples 7, 8, 9) to improve noise immunity: the bit value is taken as the majority of these three samples. Option B (sample 8 only) is a simplified model but not what typical silicon implements. Option A (sample 1) would sample immediately at the start bit edge, which is the noisiest point. Option C (sample 16) samples at the end of the bit, near the next bit's transition.

---

**Q7 -- Answer: B**

A combined write-then-read (register address write followed by data read) uses a repeated START rather than a STOP between the write and read phases. A STOP releases the bus and allows another master to take control; a repeated START maintains bus ownership. The sequence is: START -- address + W -- ACK -- register address byte -- ACK -- repeated START -- address + R -- ACK -- read data byte(s) -- NACK -- STOP. The NACK before STOP tells the slave the master does not want more bytes. Option A uses a full STOP/START, which is technically valid but risks losing bus ownership. Option C is write-only. Option D omits the register address write phase.

---

**Q8 -- Answer: C**

SPI Mode 3: CPOL=1, CPHA=1. CPOL=1 means the clock idles high. CPHA=1 means data is captured on the second (trailing) clock edge. For a clock that idles high, the first edge is falling, the second edge is rising. Therefore, data is sampled on the rising edge of SCLK, with the clock idling high. Option A describes Mode 0 (CPOL=0, CPHA=0) -- rising edge capture, clock idles low. Option B describes Mode 2 (CPOL=1, CPHA=0) -- falling edge capture, clock idles high. Option D describes Mode 1 (CPOL=0, CPHA=1) -- falling edge capture, clock idles low.

---

**Q9 -- Answer: B**

An open-drain output can only pull the pin low (to GND) when asserted; it has no ability to actively drive the pin high. When the driver releases the pin (turns off the N-FET), the pin is left floating. An external pull-up resistor is required to pull the pin to VDD when no driver is asserting it. This is the fundamental nature of open-drain and is why I2C uses open-drain: multiple devices can share a line and any one of them can pull it low. Option A is wrong; there is no active pull-high in an open-drain configuration. Option C is wrong; the direction register controls input vs output mode, not the driver state. Option D is wrong; the GPIO controller may have an optional internal pull-up that must be explicitly enabled and is typically weak (tens to hundreds of kilohms).

---

**Q10 -- Answer: A**

A preemptive priority interrupt controller allows a higher-priority interrupt to preempt a lower-priority ISR. Device A (priority 5) is higher than the currently executing interrupt (device C, priority 4), so device A preempts device C: the CPU saves its context and enters device A's ISR. Device B (priority 3) is lower than device C (priority 4), so device B does not preempt device C and waits in the pending queue until device C's ISR completes. Option B describes a non-preemptive controller. Option C would allow priority 3 to preempt priority 4, which contradicts the scheme (0 = lowest). Option D is wrong; interrupt controllers are designed to handle simultaneous arrivals without faulting.

---

**Q11 -- Answer: B**

The watchdog timer counts down from its reload value (100 ms timeout) without regard to how many kicks were missed. Once the software stops kicking the watchdog (at the moment of deadlock), the watchdog counts down from its current value to zero. If the last successful kick occurred at time T, the watchdog will fire at T + 100 ms at the latest (sooner if the kick happened mid-interval). The answer is "up to 100 ms after the last kick" -- which is option B. Option A (10 ms) would require the watchdog to fire at the next 10 ms timer interval, but the watchdog has a 100 ms timeout, not 10 ms. Option C is wrong; the watchdog has no concept of "consecutive misses". Option D is wrong; a standard watchdog timer does not detect deadlocks via software monitoring.

---

**Q12 -- Answer: C**

The minimum CS de-assertion time is 50 ns. At 500 MHz, one clock cycle = 2 ns. The number of cycles required = 50 ns / 2 ns = 25 cycles. The software must insert at least 25 NOP instructions (or equivalent) to guarantee the 50 ns minimum is met. In practice, additional instructions for loop overhead, pipeline flushing, and GPIO write latency must also be accounted for, so 25 is the minimum. Option A (1) provides only 2 ns. Option B (5) provides 10 ns. Option D (50) provides 100 ns, which is more than needed but not the minimum.

---

**Q13 -- Answer: B**

Each character at 115200 baud with 10 bits takes 10 / 115200 = approximately 86.8 us. The FIFO fires the interrupt when 8 bytes have accumulated (half-full). At that point, 8 more byte slots remain before the 16-byte FIFO overflows. The CPU therefore has 8 * 86.8 us = approximately 694 us to read at least one byte from the FIFO before overflow begins. Option A (69 us) would correspond to approximately 0.8 byte-times, which is far too short. Option C (6.9 ms) overstates by 10x. This demonstrates why UART FIFOs are important: polling at 86 us intervals is feasible but tight; 694 us gives comfortable software latency headroom at this baud rate.

---

**Q14 -- Answer: A**

In the GIC-400, the GICD_ITARGETSR (Interrupt Target Registers) specify which CPU interfaces each SPI targets, using an 8-bit field per interrupt where each bit corresponds to one CPU interface. Setting multiple bits routes the interrupt to multiple CPUs; the GIC delivers it to the highest-priority idle CPU or broadcasts depending on configuration. GICD_IGROUPR controls interrupt group assignment (Group 0 = FIQ, Group 1 = IRQ in a TrustZone system) -- not CPU targeting. GICD_NSACR controls non-secure access permissions, not routing. Option D is wrong; SPIs can target multiple CPUs using the target register mask.

---

**Q15 -- Answer: C**

The slave is still part-way through sending a byte. It holds SDA low for its current 0 bit and waits for SCL clocks that the reset master will never send, so SDA stays low and the master cannot generate a START (SDA high-to-low while SCL is high) or a STOP (SDA low-to-high while SCL is high). The I2C specification's recovery is a "bus clear": if SDA is stuck low, the master sends nine clock pulses, and the device holding SDA should release it within those nine clocks; if it does not, a hardware reset or power cycle is needed (NXP UM10204, I2C-bus specification, §3.1.16 "Bus clear"). Once SDA is released, the master issues a STOP to return every device to idle. Option A is wrong: a repeated START needs SDA to go high-to-low while SCL is high, which is impossible while SDA is stuck low. Option B is wrong: clock stretching holds SCL low, not SDA. Option D is wrong: arbitration applies when two masters drive the bus at the same time, not to a single slave stuck mid-byte.
