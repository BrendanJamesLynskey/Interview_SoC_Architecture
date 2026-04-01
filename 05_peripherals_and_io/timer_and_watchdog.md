# Timer and Watchdog

## Overview

Timers and counters are among the most used peripherals in any SoC. They underpin every real-time scheduling tick, PWM output, input capture measurement, and watchdog safety mechanism. A thorough understanding of timer counter microarchitecture — upcounting vs downcounting, compare/capture, PWM dead-time generation, and watchdog window modes — is expected at any hardware or embedded systems interview. This document covers the design rationale, register architecture, and common failure modes for each timer function.

---

## Fundamentals

### What is the difference between a timer and a counter?

**Answer:**

The distinction is about the signal being counted:

- **Timer:** Counts the SoC's internal clock (or a prescaled version of it). The counter value therefore represents elapsed time. Example: "generate an interrupt every 1 ms" uses a timer.
- **Counter:** Counts transitions on an external signal connected to the counter input pin. The counter value represents the number of external events. Example: counting pulses from a rotary encoder or measuring the frequency of an external clock.

In practice, most SoC timer peripherals can be configured as either by selecting the count source: internal clock or external pin. The hardware implementation is identical — a register that increments (or decrements) on each selected clock edge.

**Key parameters:**
- **Width:** 16-bit timers count up to 65535 events; 32-bit timers up to 4.3 billion. A 32-bit timer at 100 MHz rolls over every ~43 seconds.
- **Prescaler:** Divides the input clock before it reaches the counter. A 16-bit prescaler from a 100 MHz clock allows timing periods up to 65535 × 65535 / 100M ≈ 43 seconds with a 16-bit counter.
- **Reload value:** The value loaded into the counter at reset/overflow, setting the period.

---

### Describe the register architecture of a general-purpose timer peripheral.

**Answer:**

A typical 32-bit general-purpose timer (similar to ARM Cortex-M SysTick or STM32 TIMx):

```
Offset  Register    Fields
------  ---------   ------
0x00    CTRL        [31:16] Reserved
                    [15:8]  Unused
                    [7]     OPM         - One-pulse mode: stop after one period
                    [6]     DIR         - 0=upcounting, 1=downcounting
                    [5]     CMS[1:0]    - Centre-aligned mode select
                    [4]     ARPE        - Auto-reload preload enable (double-buffer)
                    [3]     CKD[1:0]    - Clock division: 1x, 2x, 4x
                    [2]     URS         - Update request source
                    [1]     UDIS        - Update event disable
                    [0]     CEN         - Counter enable

0x04    STATUS      [6]     CC4IF       - Capture/compare 4 interrupt flag
                    [5]     CC3IF       - Capture/compare 3 interrupt flag
                    [4]     CC2IF       - Capture/compare 2 interrupt flag
                    [3]     CC1IF       - Capture/compare 1 interrupt flag
                    [1]     CC1OF       - Capture overcapture flag
                    [0]     UIF         - Update interrupt flag (overflow/underflow)

0x08    EGR         [0]     UG          - Software update event (force reload)

0x0C    CCMR1       [15:8]  OC2M[2:0]  - Output compare 2 mode
                    [7:0]   OC1M[2:0]  - Output compare 1 mode

0x10    CCMR2       [15:8]  OC4M[2:0]  - Output compare 4 mode
                    [7:0]   OC3M[2:0]  - Output compare 3 mode

0x14    CCER        [12]    CC4P        - Capture/compare 4 polarity
                    [8]     CC3P        - Capture/compare 3 polarity
                    [4]     CC2P        - Capture/compare 2 polarity
                    [0]     CC1P        - Capture/compare 1 polarity

0x18    CNT         [31:0]  Counter value (read/write)

0x1C    PSC         [15:0]  Prescaler value (actual divisor = PSC + 1)

0x20    ARR         [31:0]  Auto-reload register (period register)

0x24    CCR1        [31:0]  Capture/compare register 1

0x28    CCR2        [31:0]  Capture/compare register 2

0x2C    CCR3        [31:0]  Capture/compare register 3

0x30    CCR4        [31:0]  Capture/compare register 4
```

**Auto-reload preload (ARPE):** When set, writes to ARR go to a shadow register. The new period takes effect only at the next update event (counter overflow). Without this, writing a new ARR mid-cycle can cause a spurious short or long period — a critical correctness feature for PWM frequency changes.

**Shadow registers:** CCRx registers also have shadows. The compare value is committed to the active shadow only at the update event, preventing glitches in PWM output.

---

## Timer Modes

### Explain upcounting, downcounting, and centre-aligned (up/down) timer modes.

**Answer:**

**Upcounting mode:**
```
CNT: 0 → 1 → 2 → ... → ARR → 0 → 1 → ... (wraps at ARR)
                          ^
                          Update event (overflow), interrupt if enabled
```
Period = (ARR + 1) / f_timer. Compare match fires when CNT == CCRx while counting up.

**Downcounting mode:**
```
CNT: ARR → ARR-1 → ... → 1 → 0 → ARR → ... (reloads at 0)
                                   ^
                                   Update event (underflow)
```
Period is the same. Useful in some trigger applications. Compare match fires when CNT == CCRx while counting down.

**Centre-aligned (up/down) mode:**
```
CNT: 0 → 1 → ... → ARR-1 → ARR → ARR-1 → ... → 1 → 0 → 1 → ...
                             ^                        ^
                             Direction reverses       Direction reverses
                             (overflow)               (underflow, update event)
```
The counter counts up to ARR, then counts back down to 0. The fundamental period is:
```
T = 2 × ARR / f_timer
```

**Why centre-aligned for PWM?** In centre-aligned mode, the PWM output transitions are symmetric around the centre of the period. The resulting output waveform has its fundamental harmonic at f_timer / (2 × ARR) — the same as upcounting with an equivalent period — but the symmetric switching reduces harmonic content. More importantly, in three-phase motor drive applications, centre-aligned PWM for all three phases ensures the high-side and low-side switches never overlap, and the phase current ripple is minimised. It also provides a natural synchronisation point at the peak and trough of the counter for ADC triggering.

---

### What is output compare mode and how is it used to generate a PWM signal?

**Answer:**

In output compare mode, a hardware comparator continuously compares CNT against CCRx. When they match, a hardware event occurs:

**Output compare modes for channel 1:**
- **Toggle:** OC1 output flips state on match.
- **Force inactive:** OC1 output forced LOW regardless of counter.
- **Force active:** OC1 output forced HIGH regardless of counter.
- **PWM mode 1:** OC1 HIGH while CNT < CCR1 (in upcounting). HIGH when CNT > CCR1 (active-low variant).
- **PWM mode 2:** OC1 LOW while CNT < CCR1 (inverse of mode 1).

**Generating a 50 kHz PWM at 25% duty cycle from a 100 MHz clock:**

```
Step 1: Set prescaler
  PSC = 0  (no prescaler, f_timer = 100 MHz)

Step 2: Set period (ARR)
  T_period = 1 / 50kHz = 20 µs
  ARR = (f_timer × T_period) - 1 = (100e6 × 20e-6) - 1 = 1999
  CNT counts 0 → 1999, period = 2000 clocks = 20 µs ✓

Step 3: Set duty cycle (CCR1)
  Duty = 25% → active time = 5 µs = 500 clocks
  CCR1 = 500
  OC1 HIGH while CNT < 500 (PWM mode 1, upcounting)

Step 4: Enable
  CCMR1: OC1M = PWM mode 1
  CCER:  CC1E = 1 (enable output)
  CTRL:  CEN  = 1 (enable counter)
```

**Changing duty cycle at runtime:** Write the new value to CCR1 (the shadow register commits at the next update event if ARPE is set). No glitch occurs in the output because the new CCR value only takes effect at the next cycle boundary.

---

## Watchdog Timer

### Describe the purpose and operation of a watchdog timer. What is the difference between a basic and a windowed watchdog?

**Answer:**

A watchdog timer is a hardware safety mechanism that generates a system reset if the application firmware stops refreshing it within the expected time interval. Its purpose is to recover from software hangs — infinite loops, deadlocks, or stack overflows that would otherwise leave the system unresponsive.

**Basic watchdog operation:**

```
WDT counter: RELOAD → RELOAD-1 → ... → 1 → 0 → RESET (if not refreshed)
                                              ^
                                              Timeout reset
```

The firmware periodically writes a specific key value (e.g., `0x1234` then `0x5678`) to the Kick register. This reloads the counter with the RELOAD value, preventing timeout. If the firmware fails to kick within the timeout period, the counter reaches zero and the watchdog asserts RESET.

**Window watchdog operation:**

The window watchdog adds a lower bound on when the kick is acceptable:

```
Counter value:
  RELOAD
    |     ^--- Kick too early (RESET): counter > WINDOW
    |
  WINDOW threshold
    |     ^--- Valid kick window (counter <= WINDOW)
    |
    0    <--- Timeout RESET (counter reached 0 without kick)
```

- If the kick occurs while CNT > WINDOW: the hardware interprets this as the software kicking too often — a sign that the software is executing faster than expected, possibly in a tight error-recovery loop. A RESET is triggered.
- If the kick occurs while CNT <= WINDOW: accepted, counter reloaded.
- If no kick occurs before CNT reaches 0: RESET.

**Why window mode is preferred for safety-critical systems:**

Basic watchdog can be trivially defeated: a firmware bug that kicks the watchdog at an incorrect rate (too frequently) will never be caught. Window watchdog enforces that the software is executing at a predictable rate — it catches both too-slow (hang) and too-fast (runaway loop) failures. IEC 61508 and ISO 26262 functional safety standards require window watchdog (or equivalent) for safety-relevant software.

---

### What are the common configuration registers for a watchdog timer?

**Answer:**

```
Offset  Register     Fields
------  -----------  ------
0x00    CTRL         [31:8]  Reserved
                     [7]     WDOG_EN      - Enable watchdog (set-only, cannot clear)
                     [6]     RESET_EN     - 1=reset on timeout, 0=interrupt only
                     [5]     INTR_EN      - Enable pre-timeout interrupt
                     [4]     WINDOW_EN    - Enable window mode
                     [3:2]   CLK_DIV      - Prescaler: 1, 2, 4, 8
                     [1:0]   TIMEOUT_SEL  - Selects from 4 preset timeout values
                                           (or configures via LOAD register)

0x04    LOAD         [31:0]  Reload value (write-only)
                              Writes must use unlock sequence

0x08    VALUE        [31:0]  Current counter value (read-only)

0x0C    INTR_STAT    [1]     WINDOW_VIOL  - Window violation flag, W1C
                     [0]     TIMEOUT      - Timeout interrupt flag, W1C

0x10    WINDOW       [31:0]  Window threshold: kick rejected if VALUE > WINDOW
                              (write-only, requires unlock)

0x14    LOCK         [31:0]  Unlock sequence: write 0x1ACCE551 then 0 to unlock
                              Read returns lock status: 0=unlocked, 1=locked
                              Relocks after first write to any register

0x18    KICK         [31:0]  Write 0xDEADBEEF to refresh the counter
                              (write-only, window check applied)
```

**Security design notes:**

The LOCK/unlock sequence prevents accidental watchdog configuration changes (e.g., from a run-amok pointer write). The unlock sequence requires two specific writes in sequence — a random bus transaction cannot accidentally produce this sequence. After one register write, the block re-locks.

Once WDOG_EN is set, it cannot be cleared without a reset. This prevents a firmware bug from disabling the watchdog after enabling it. Some designs route the WDOG_EN bit through a dedicated fuse or secure boot flag to prevent production firmware from accidentally leaving the watchdog disabled.

**Pre-timeout interrupt:** The INTR_EN bit enables an interrupt a fixed time (e.g., 25% of the timeout period) before the hard reset fires. This allows the firmware to log a diagnostic record to non-volatile storage before the reset occurs, giving a root-cause trail.

---

## Capture/Compare

### Explain input capture mode and how it measures the frequency of an external signal.

**Answer:**

In input capture mode, the timer captures (latches) the current counter value into a CCRx register when a configured edge occurs on an external input pin.

**Measuring signal frequency:**

```
External signal:  __|‾‾‾|__|‾‾‾|__|‾‾‾|_
Captured value:   T1      T2      T3
Rising edges
```

The period of the external signal equals the difference between successive captured values:

```
Period = (T2 - T1) / f_timer
Frequency = f_timer / (T2 - T1)
```

**Software algorithm:**

```c
uint32_t t1, t2, period;

// ISR on each capture event
void TIM_CC_IRQHandler(void) {
    if (TIM->STATUS & CC1IF) {
        t2 = TIM->CCR1;  // Read captured value
        period = t2 - t1; // Handles counter wrap correctly if width >= 32-bit
                          // or if |t2-t1| < 2^15 for 16-bit (unsigned subtraction)
        t1 = t2;
        frequency_hz = TIMER_CLOCK_HZ / period;
        TIM->STATUS = CC1IF; // Clear flag (W1C)
    }
}
```

**Counter wrap handling:** If the counter overflows between two captures, the difference `t2 - t1` must be computed with unsigned arithmetic modulo 2^N (the counter width). Unsigned subtraction in C naturally handles this for any single overflow: if `t1 = 0xFFFF0000` and `t2 = 0x00001000` (counter overflowed), `t2 - t1 = 0x00011000` which is correct.

**Prescaler selection:** To measure very low frequencies, the counter period must be longer than the measured signal period. Use the prescaler to slow the counter. To measure very high frequencies, ensure the counter ticks fast enough: resolution = 1 / f_timer. For a 100 MHz timer measuring a 50 MHz signal, resolution is 1 tick per 10 ns — only 2 ticks per period, inadequate. Use a higher-frequency reference or frequency division.

---

## PWM Generation

### How is dead-time insertion implemented in complementary PWM for motor drive applications?

**Answer:**

In H-bridge or three-phase inverter motor control, a high-side switch and a low-side switch must never conduct simultaneously — this would create a shoot-through path directly across the supply, destroying the switches. Dead time is a deliberately inserted delay between turning off one switch and turning on the complementary switch.

**Hardware implementation:**

Advanced timer peripherals (e.g., STM32 TIM1/TIM8) provide complementary outputs OC1 and OC1N with a programmable dead-time generator:

```
PWM signal (OC1):
  __|‾‾‾‾‾‾‾‾‾‾‾‾‾‾|____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾|__

OC1 with dead-time (high-side gate):
  ___|‾‾‾‾‾‾‾‾‾‾‾‾|_____|‾‾‾‾‾‾‾‾‾‾‾‾|__
     ^             ^
     DT delay      DT delay (rising edge delayed)

OC1N with dead-time (low-side gate, complement):
  ____|‾‾‾‾‾‾‾‾‾‾|______|‾‾‾‾‾‾‾‾‾‾|____
                  ^                 ^
                  DT delay          DT delay
```

Both rising edges are delayed by the dead-time value DTG (Dead Time Generator register). The falling edges track the original PWM edges. This ensures a gap on both transitions.

**DTG register encoding (ARM advanced timer):**

The DTG field is 8 bits and uses a non-linear encoding to provide both fine and coarse granularity:
```
DTG[7:5] = 0xx: dead-time = DTG[6:0] × t_DTS
DTG[7:5] = 10x: dead-time = (64 + DTG[5:0]) × 2 × t_DTS
DTG[7:5] = 110: dead-time = (32 + DTG[4:0]) × 8 × t_DTS
DTG[7:5] = 111: dead-time = (32 + DTG[4:0]) × 16 × t_DTS
```
where t_DTS = 1/f_DTS, typically = 1/f_timer or divided by the CKD prescaler.

**Dead-time constraints:** Dead time must be:
- Long enough to ensure the power switch fully turns off before the complementary switch turns on (switch turn-off time + gate driver propagation).
- Short enough that the effective duty cycle is not significantly reduced.
- Typically 100 ns to 1 µs for Silicon IGBTs; 10-50 ns for SiC MOSFETs.

---

## Design Considerations

### How do you calculate the minimum timer resolution needed for a real-time scheduler tick?

**Answer:**

**Context:** An RTOS tick interrupt must fire at a regular rate (e.g., 1000 Hz for a 1 ms tick) with sufficient resolution to minimise jitter.

**Given:**
- System clock: 120 MHz
- Required tick rate: 1000 Hz (1 ms period)
- Timer width: 32-bit
- Acceptable tick jitter: < 1 µs

**Calculation:**

```
Timer clock = 120 MHz → t_tick = 1 / 120 MHz = 8.33 ns per count

Required counts per tick: N = f_timer / f_tick = 120e6 / 1000 = 120,000

ARR = N - 1 = 119,999

Resolution: 1 tick = 8.33 ns  (far better than the 1 µs jitter requirement)

Maximum measurable period (no prescaler, 32-bit):
  T_max = 2^32 / 120e6 = 35.8 seconds  (adequate)
```

No prescaler is needed. The 32-bit counter at 120 MHz gives 8.33 ns resolution with periods up to 35.8 seconds — the timer can serve both the 1 ms scheduler tick and, with different channels, longer-period events.

**Prescaler trade-off:** If the timer were 16-bit:
```
Max period (no prescaler): 2^16 / 120e6 = 546 µs  (insufficient for 1 ms)
With PSC = 1 (divide by 2): max = 1.09 ms ✓ but resolution = 16.67 ns
With PSC = 3 (divide by 4): max = 2.18 ms, resolution = 33.33 ns
```

A 16-bit timer with PSC=1 works for a 1 ms tick: ARR = (120e6 / 2 / 1000) - 1 = 59,999. Resolution 16.67 ns, jitter well within budget.

**Jitter sources beyond timer resolution:**
- Interrupt latency (12 cycles on Cortex-M3 = 100 ns at 120 MHz)
- ISR prologue overhead
- Higher-priority interrupts delaying the timer ISR

The timer resolution must be significantly finer than the allowable jitter to have headroom for these overheads.

---

### What is the watchdog refresh problem in RTOS-based systems, and how is it solved?

**Answer:**

**The problem:** In an RTOS with multiple tasks, which task is responsible for kicking the watchdog? If a single dedicated task does it:

1. The watchdog task could kick even when other tasks are hung, giving a false "all is well" signal.
2. If the watchdog task itself hangs, the system resets even when everything else is healthy.
3. If the watchdog task is lowest priority, a high-priority task spin-locking will starve the watchdog task, causing spurious resets.

**Solution 1: Software vote register**

Each critical task sets a bit in a shared vote register when it has completed its work for the current period. The watchdog task only kicks the hardware watchdog when all bits are set:

```c
#define TASK_A_VOTE  (1 << 0)
#define TASK_B_VOTE  (1 << 1)
#define TASK_C_VOTE  (1 << 2)
#define ALL_VOTES    (TASK_A_VOTE | TASK_B_VOTE | TASK_C_VOTE)

volatile uint32_t wdt_votes = 0;

// Called by each task at the end of its work
void wdt_vote(uint32_t task_bit) {
    __atomic_or_fetch(&wdt_votes, task_bit, __ATOMIC_SEQ_CST);
}

// Watchdog task (highest priority, short period)
void wdt_task(void) {
    while (1) {
        if ((wdt_votes & ALL_VOTES) == ALL_VOTES) {
            wdt_votes = 0;       // reset for next cycle
            WDT->KICK = 0xDEADBEEF;
        }
        // else: do not kick; allow timeout reset
        vTaskDelay(WDT_KICK_PERIOD_MS);
    }
}
```

**Solution 2: Windowed watchdog with RTOS timer**

Use the window watchdog's timing constraints directly: the RTOS timer callback that kicks the watchdog can only execute within the scheduler tick boundary. If the RTOS tick is running, the callback fires; if the RTOS is hung, the callback is never invoked and the watchdog fires. The window prevents the firmware from kicking too early (if the RTOS is running a tight error loop faster than expected).

**Solution 3: Hardware task monitor**

Some MCUs (Infineon AURIX, NXP S32) include a "Software Execution Monitor" or "Safety Management Unit" that tracks program counter ranges and task switch counts directly in hardware, independent of the RTOS scheduler. This gives cycle-accurate monitoring without software cooperation.
