# Interrupt Controller

## Overview

An interrupt controller is the subsystem that collects asynchronous event signals from peripherals and external pins, arbitrates between multiple simultaneous events, and delivers a prioritised interrupt request to the processor core. The two dominant architectures in embedded and application-processor SoCs are ARM's Nested Vectored Interrupt Controller (NVIC) — tightly coupled to the Cortex-M core — and RISC-V's Platform-Level Interrupt Controller (PLIC), an external, bus-attached design. Understanding both, as well as the hardware interrupt handling flow, is central to any SoC architecture interview.

---

## Fundamentals

### What is the difference between a vectored and a non-vectored interrupt controller?

**Answer:**

**Non-vectored (polled):** When an interrupt occurs, the processor jumps to a single, fixed interrupt service routine (ISR) entry point. That ISR reads an interrupt status register, determines which source fired, and branches to the appropriate handler. Simple to implement in hardware, but slow — the latency includes the polling loop.

**Vectored:** Each interrupt source has a pre-defined entry point address (a "vector") stored in a vector table in memory. When the interrupt controller selects the highest-priority pending interrupt, it provides the vector index directly to the processor. The processor fetches the handler address from the vector table in one memory access and branches, without any software polling.

**Nested vectored (NVIC):** Extends the vectored model to support pre-emption. If a higher-priority interrupt arrives while the CPU is executing an ISR, the current ISR state is automatically saved (stacked), and the higher-priority ISR begins immediately. On return from the higher-priority ISR, the lower-priority ISR resumes. The processor and interrupt controller cooperate in hardware to manage the priority stack, enabling tail-chaining (no stack push/pop overhead between ISRs of adjacent priority levels).

**Impact on design:** The NVIC's hardware-managed stack push/pop adds 12 cycles of interrupt latency but eliminates all software overhead for context save. For Cortex-M3/M4 the worst-case interrupt latency is 12 cycles; with tail chaining it is 6 cycles for back-to-back interrupts. This is why NVIC-based Cortex-M cores dominate hard real-time applications.

---

### Describe the NVIC architecture. What registers does it expose?

**Answer:**

The ARM NVIC is a fixed-function hardware block tightly integrated with the Cortex-M pipeline. Key architectural properties:

- Up to 240 external interrupts (IRQ0-IRQ239) plus 16 system exceptions (Reset, NMI, HardFault, etc.)
- Priority levels: 8 to 256 configurable levels (SoC-designer choice, encoded in 3 to 8 bits)
- Group priority and sub-priority split for preemption control (PRIGROUP field in AIRCR)
- Pending and active state tracked per interrupt in hardware

**Memory-mapped registers (base address 0xE000E000 in Cortex-M):**

```
Register              Address     Width   Description
--------------------  ----------  ------  -----------
ISER[0..7]           0xE000E100  32-bit  Interrupt Set Enable Register
                                          Write 1 to enable interrupt N
                                          (N = word index × 32 + bit position)

ICER[0..7]           0xE000E180  32-bit  Interrupt Clear Enable Register
                                          Write 1 to disable interrupt N

ISPR[0..7]           0xE000E200  32-bit  Interrupt Set Pending Register
                                          Write 1 to force interrupt N pending
                                          (software interrupt injection)

ICPR[0..7]           0xE000E280  32-bit  Interrupt Clear Pending Register
                                          Write 1 to clear pending state

IABR[0..7]           0xE000E300  32-bit  Interrupt Active Bit Register (read-only)
                                          Bit set while ISR is executing

IPR[0..59]           0xE000E400  32-bit  Interrupt Priority Registers
                                          8 bits per interrupt (upper bits used)

STIR                 0xE000EF00  32-bit  Software Trigger Interrupt Register
                                          Privileged software interrupt injection
```

**Priority encoding:** If only 3 priority bits are implemented, they occupy bits [7:5] of each byte in IPR, and bits [4:0] read as zero. Priority 0 is highest, 0xFF (or 0xE0 in a 3-bit system) is lowest. The NVIC compares the priority of the incoming interrupt against the currently executing ISR's priority stored in IPSR. Pre-emption occurs only when the new interrupt's priority number is numerically lower (higher priority).

**PRIGROUP:** Splits the priority field into group priority (determines pre-emption) and sub-priority (determines which ISR runs first when two have the same group priority, but neither can pre-empt the other).

---

### Describe the RISC-V PLIC architecture and how it differs from the NVIC.

**Answer:**

The RISC-V Platform-Level Interrupt Controller (PLIC) is defined in the RISC-V Privileged Architecture specification. It is a bus-attached peripheral, not a processor-coupled unit.

**Key properties:**
- Supports up to 1023 interrupt sources (source 0 is reserved as "no interrupt")
- Per-source configurable priority (1 to 7 in the standard, implementation-defined depth)
- Per-hart (hardware thread) interrupt enable bits
- Per-hart priority threshold register — interrupts below the threshold are masked at the PLIC before reaching the hart
- One external interrupt line (EIP) per hart; the hart polls the PLIC claim register for the source ID

**PLIC register map (base address implementation-defined):**

```
Offset              Register            Description
------------------  ------------------  -----------
0x000000 + 4×n      PRIORITY[n]         Priority of source n (n = 1..1023)
0x001000 + offset   PENDING[0..31]      Bit set if source n is pending
0x002000 + offset   ENABLE[hart][word]  Enable bits per hart per source
0x200000 + 0x1000×h THRESHOLD[hart]     Priority threshold for hart h
0x200004 + 0x1000×h CLAIM_COMPLETE[h]  Read=claim (returns highest prio ID),
                                         Write=complete (signals handler done)
```

**Interrupt flow in PLIC:**

1. Source N asserts its interrupt request line.
2. PLIC stores the pending bit for source N.
3. PLIC evaluates all enabled, pending sources against each hart's threshold.
4. PLIC asserts EIP (External Interrupt Pending) to any hart where at least one enabled source exceeds the threshold.
5. Hart's interrupt handling code reads `CLAIM_COMPLETE` — the PLIC returns the highest-priority source ID and clears the pending bit.
6. Hart executes the ISR for that source.
7. Hart writes the source ID back to `CLAIM_COMPLETE` to signal completion.

**Critical difference from NVIC:** The PLIC uses a claim/complete handshake. Step 7 (completion write) is mandatory — without it, the PLIC treats the interrupt as still active and will not re-assert EIP for that source even if it fires again. Forgetting the completion write is a common software bug in RISC-V BSP bring-up.

**PLIC vs NVIC comparison:**

| Property               | NVIC (Cortex-M)              | PLIC (RISC-V)                    |
|------------------------|------------------------------|----------------------------------|
| Coupling               | Core-coupled                 | Bus-attached peripheral           |
| Vectoring              | Hardware vector table fetch  | Software reads claim register     |
| Nesting                | Hardware-managed stack       | Software-managed (firmware saves) |
| Multi-hart support     | Per-core NVIC instance       | Single PLIC serves all harts      |
| Priority levels        | Up to 256                    | Up to 7 (spec minimum)            |
| Interrupt latency      | ~12 cycles                   | Higher (bus access + software)    |

---

## Interrupt Handling

### Describe the complete hardware interrupt handling flow from assertion to ISR entry on a Cortex-M3.

**Answer:**

**Cycle-by-cycle flow:**

1. **Peripheral asserts IRQ** (e.g., UART RX FIFO threshold crossed, level-high signal on NVIC input N).

2. **NVIC sampling:** The NVIC samples interrupt inputs synchronously on the system clock. An asynchronous interrupt input is first synchronised (two-flop) before being presented to the pending state logic.

3. **Pending state set:** The NVIC sets the pending bit for IRQ N. This is an OR-latch: even a brief pulse sets the pending bit and holds it until cleared.

4. **Priority evaluation:** The NVIC compares IRQ N's configured priority against the current execution context priority:
   - If the processor is in Thread mode (no ISR) and the interrupt is enabled: assert the interrupt to the pipeline.
   - If in an ISR and the new interrupt priority is higher (numerically lower): assert the interrupt for pre-emption.
   - Otherwise: interrupt waits in pending state.

5. **Pipeline interrupt acceptance:** The Cortex-M3 pipeline detects the interrupt request. It completes the current instruction (or aborts it if it is a multi-cycle instruction and the microcode can safely restart it).

6. **Exception entry — automatic state save (hardware push):** The core pushes 8 registers onto the current stack pointer (PSP or MSP) in a specific order:
   ```
   Stack grows down. On exception entry, pushed in this order:
   xPSR  -->  [SP - 4]
   PC    -->  [SP - 8]   (return address, = PC of interrupted instruction)
   LR    -->  [SP - 12]  (previous link register value)
   R12   -->  [SP - 16]
   R3    -->  [SP - 20]
   R2    -->  [SP - 24]
   R1    -->  [SP - 28]
   R0    -->  [SP - 32]
   SP updated to (old_SP - 32)
   ```
   These 8 registers are the "caller-saved" registers in the ARM ABI. The hardware saves exactly those registers that a C ISR would need to restore on return, allowing the ISR to be a normal C function without any prologue/epilogue.

7. **Vector fetch:** In parallel with the stack push (cycles overlap), the core reads the interrupt vector from the vector table: address = `VTOR + (N + 16) × 4`. This is why the vector table must be 256-byte aligned (the lower bits of VTOR are always zero).

8. **LR loaded with EXC_RETURN:** A special magic value is loaded into LR (e.g., `0xFFFFFFF9` for return to Thread mode using MSP). The `BX LR` instruction at the end of the ISR uses this to trigger exception return.

9. **ISR executes.** The NVIC marks IRQ N as "active". It clears the pending bit.

10. **Exception return:** The ISR executes `BX LR` with the `EXC_RETURN` value. The core pops the 8 saved registers from the stack. PC is restored to the return address. Execution of interrupted code resumes.

**Total latency:** 12 cycles for exception entry (overlapped stack push + vector fetch) in the zero-wait-state case. Each wait state on the stack push or vector fetch adds cycles linearly.

---

## Priority Management

### What is interrupt priority inversion, and how is it prevented?

**Answer:**

**Priority inversion** in interrupt context occurs when a high-priority ISR is blocked from running because a resource it needs is held by a low-priority context that itself cannot run because a medium-priority context is executing. Unlike mutex-based priority inversion in RTOS tasks, interrupt-level priority inversion is rare but does occur.

**Practical scenario:**

1. Low-priority ISR begins and acquires a spinlock on a shared data structure.
2. A medium-priority interrupt fires, pre-empts the low-priority ISR.
3. A high-priority interrupt fires, pre-empts the medium-priority ISR.
4. The high-priority ISR tries to acquire the same spinlock — it spins.
5. The medium-priority ISR cannot be pre-empted by the high-priority ISR (already active), and the low-priority ISR cannot run to release the lock.
6. Deadlock.

**Prevention strategies:**

1. **Critical sections (disable interrupts):** The most common approach on Cortex-M: set `PRIMASK=1` (blocks all interrupts below NMI) before accessing shared data. The low-priority ISR holds the resource only for the duration of the critical section, preventing medium-priority pre-emption.

2. **BASEPRI masking:** More surgical than PRIMASK. Set `BASEPRI` to the priority of the high-priority ISR that shares the resource. Only interrupts above that threshold can pre-empt. This allows truly urgent interrupts (e.g., NMI) to still fire.

3. **Avoid shared state:** The cleanest architectural solution. Design ISRs to operate on private data structures. Use a producer/consumer ring buffer between the ISR (producer) and the main/RTOS task (consumer). Ring buffers with a single writer and single reader require no locking if properly implemented with appropriate memory barriers.

4. **Priority ceiling:** Temporarily raise the current execution context priority to the ceiling of all ISRs that share the resource for the duration of the critical section. This is the interrupt analog of the Priority Ceiling Protocol in RTOS design.

---

## Level vs Edge Triggered

### Compare level-triggered and edge-triggered interrupts. When should each be used?

**Answer:**

**Level-triggered:** The interrupt controller asserts the interrupt request as long as the interrupt source line is active (HIGH or LOW, as configured). The pending bit is re-asserted each sampling cycle while the line remains active. The interrupt will re-fire immediately on return from the ISR if the source has not been cleared.

```
IRQ line:   ______|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___
                  ^                 ^
               asserted          deasserted
               (ISR fires)       (only now does ISR stop re-firing)
```

**Edge-triggered:** The interrupt controller captures the transition (rising edge, falling edge, or both). The pending bit is set by the event and held in the latch regardless of the current line state. The pending bit is cleared when the ISR begins (or when explicitly cleared by software).

```
IRQ line:   ______|‾‾‾|_____________________________
                  ^   ^
               asserts  deasserts
               pending  (pending stays set until cleared)
```

**When to use level-triggered:**
- When the hardware assertion is guaranteed to persist until software services it (e.g., a FIFO full signal — the FIFO remains full until the ISR reads data).
- When it is safe to miss an edge (if the ISR returns without clearing the source, the level-trigger re-fires — a form of guaranteed delivery).
- PCI and PCI Express interrupts (shared INTx lines, which are open-collector and level-signalled for this reason).
- PLIC uses level-triggered semantics for this reason — reliable in multi-hart systems.

**When to use edge-triggered:**
- When the interrupt event is a brief pulse that may be deasserted before the ISR runs.
- When multiple events must be counted — an edge is counted per event, whereas a level is counted once regardless of duration.
- When the source cannot be acknowledged quickly (software must not deadlock in level mode).

**Critical edge-triggered gotcha:** If two events arrive before the ISR runs, the second edge may be missed — only one pending bit is stored. Systems that need guaranteed delivery of all events must use level triggering or a hardware event counter.

**NVIC defaults:** The Cortex-M NVIC uses level-sensitive inputs for external peripherals (the peripheral asserts and holds the line until the ISR clears it). Configuring a peripheral IRQ as edge-triggered requires the peripheral to drive a pulse, or the SoC must have an edge-detect wrapper between the peripheral output and the NVIC input.

---

## Implementation Patterns

### Design a 4-input priority interrupt controller with configurable priority levels. Describe the logic.

**Answer:**

**Specification:**
- 4 interrupt sources: IRQ[3:0]
- 4 priority levels per source: 2-bit priority register per IRQ (0 = highest, 3 = lowest)
- Level-sensitive inputs
- Outputs: IRQ_OUT (to processor), IRQ_ID[1:0] (source ID of selected interrupt)

**Architecture:**

```
IRQ[3:0]  ─────────────────────┐
                                 v
ENABLE[3:0] ──────────────> AND gate (mask disabled sources)
                                 |
                                 v
                         Pending[3:0]  (ORed with software set)
                                 |
                                 v
              ┌──────────────────────────────┐
              │  Priority comparator tree    │
              │                              │
              │  For each active IRQ:        │
              │  {PRIORITY[irq], ~irq}       │
              │  Compare to find minimum     │
              │  (lowest priority number)    │
              └─────────────────────────────┘
                                 |
                    ┌────────────┴────────────┐
                    v                         v
               IRQ_OUT = 1              IRQ_ID[1:0]
               (if any pending)         (selected source)
```

**Priority comparison logic (combinational):**

The comparator selects the pending IRQ with the lowest priority number. To break ties deterministically, the lowest-numbered IRQ wins (fixed priority within equal levels). The combined sort key is `{PRIORITY[irq], irq}` — sort ascending.

```
// Pseudocode
best_priority = 2'b11;  // worst case
best_id       = 2'bXX;

for i in 0 to 3:
    if pending[i] and {priority[i], i} < {best_priority, best_id}:
        best_priority = priority[i]
        best_id       = i

IRQ_OUT = (any pending enabled IRQ exists)
IRQ_ID  = best_id
```

**Vectored extension:** To support a vector table, add a ROM lookup: `VECTOR_ADDR = BASE_ADDR + IRQ_ID × 4`. The processor reads this address to get the ISR entry point.

**Masked-priority threshold:** Add a threshold register `THRESHOLD[1:0]`. Only IRQs with priority < THRESHOLD (numerically) pass through. This mirrors the PLIC claim threshold and allows an active ISR to suppress lower-priority re-entry.

**Register map:**
```
0x00  ENABLE[3:0]     - per-source enable bits
0x04  PENDING[3:0]    - read: pending state; write 1: clear (W1C)
0x08  PRIORITY0[1:0]  - priority for IRQ0
0x0C  PRIORITY1[1:0]  - priority for IRQ1
0x10  PRIORITY2[1:0]  - priority for IRQ2
0x14  PRIORITY3[1:0]  - priority for IRQ3
0x18  THRESHOLD[1:0]  - minimum priority threshold
0x1C  IRQ_ID[1:0]     - read: currently selected IRQ source (read-only)
```

---

### What is interrupt coalescing and when is it valuable?

**Answer:**

Interrupt coalescing (also called interrupt moderation or interrupt throttling) is a technique where the interrupt controller delays asserting an interrupt to the processor, accumulating multiple events into a single interrupt, in order to reduce interrupt overhead at the cost of latency.

**Mechanism:** Two timer-based thresholds are used:
- **Count threshold:** Assert the interrupt after N events have accumulated.
- **Time threshold:** Assert the interrupt at most T microseconds after the first event, even if fewer than N events have arrived.

The time threshold ensures that a low-traffic period still delivers interrupts within bounded latency.

**When valuable:**

1. **High-bandwidth network interfaces (10G Ethernet, PCIe):** At 10 Gbps with 64-byte minimum frames, a NIC can generate ~19 million interrupts per second. Each interrupt has ~100-300 ns overhead (interrupt latency + ISR prologue/epilogue). Without coalescing, the CPU spends more than 100% of its time in interrupt handling — more cycles than exist. Coalescing to 8 frames per interrupt reduces overhead by 8×.

2. **Storage controllers:** NVMe SSDs processing thousands of IOPS can overwhelm the CPU interrupt path. Coalescing I/O completion interrupts reduces overhead while keeping average latency low.

3. **USB host controllers:** USB frame-based timing naturally provides a coalescing structure (1ms USB frames).

**Cost:** Increased latency for individual events. Unsuitable for low-latency control applications (motor drives, audio, real-time sensor loops). The count and time thresholds must be tuned for the application's latency budget.

**SoC implementation:** The interrupt controller includes a per-source or per-queue counter and a retriggerable timer. When either threshold fires, the pending bit is set and the interrupt is forwarded to the NVIC/PLIC. The ISR reads all accumulated events in a batch (the FIFO depth absorbs the coalescing window).
