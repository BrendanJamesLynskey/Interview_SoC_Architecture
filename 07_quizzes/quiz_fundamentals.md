# Quiz: SoC Fundamentals

15 multiple-choice questions covering SoC building blocks, memory maps, address decoding, clock architecture, and reset sequencing. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** Which of the following best describes the primary role of a bus fabric in an SoC?

- A) To supply regulated power to all IP blocks simultaneously
- B) To route clock signals from the PLL to all flip-flops on the die
- C) To provide a shared communication infrastructure connecting masters and slaves
- D) To perform address translation between virtual and physical address spaces

---

**Q2.** A 32-bit AXI master accesses a peripheral whose base address is 0x4000_0000 and whose address space is 64 KB. Which address range is correctly assigned to this peripheral?

- A) 0x4000_0000 -- 0x4000_7FFF
- B) 0x4000_0000 -- 0x4000_FFFF
- C) 0x4000_0000 -- 0x4001_FFFF
- D) 0x4000_0000 -- 0x3FFF_FFFF

---

**Q3.** In an SoC clock tree, what is the primary purpose of a clock buffer inserted between a PLL output and a large array of flip-flops?

- A) To reduce the clock frequency to match the operating speed of flip-flops
- B) To drive the high capacitive load of the clock network and reduce clock skew
- C) To multiply the PLL output frequency before distribution
- D) To convert the single-ended PLL output to a differential clock signal

---

**Q4.** An SoC contains a processor core (master), a SRAM, a UART peripheral, and a DMA controller. Which of the following is most commonly implemented as a bus master rather than a bus slave?

- A) SRAM
- B) UART
- C) DMA controller
- D) ROM

---

**Q5.** The term "memory-mapped I/O" means that:

- A) Peripheral registers are accessed using the same address bus and read/write instructions as system memory
- B) Peripheral FIFOs are backed by DRAM rather than SRAM
- C) Peripheral interrupts are routed through a dedicated memory controller
- D) All peripheral DMA transfers must pass through a cache controller

---

### Intermediate (Q6 -- Q11)

**Q6.** An SoC designer allocates a contiguous 256 MB region starting at 0x2000_0000 for external DDR. A natural binary address decoder is used. Which of the following sets of address bits uniquely selects this region and no other?

- A) A[31:28] = 0x2
- B) A[31:28] = 0x2 and A[27:0] = any
- C) A[31:28] must equal 4'b0010 (decode bits [31:28] = 0x2)
- D) A[31:27] = 5'b0010_0 (decode the top 5 bits)

---

**Q7.** A synchronous reset is released for a CPU core on the rising edge of the processor clock. Which statement best describes a key hazard of this approach?

- A) Synchronous resets cannot be used with flip-flops that only have asynchronous reset inputs
- B) Synchronous resets are incompatible with clock gating because the reset pulse may be masked
- C) Synchronous resets are inherently non-deterministic due to metastability on the reset line
- D) Synchronous resets always cause a race condition between the reset and data paths

---

**Q8.** An SoC has a 1 GHz CPU clock domain and a 100 MHz peripheral bus domain. A control register in the peripheral domain must be read by software running on the CPU. Why is it not safe to directly sample the register value on the CPU clock without additional circuitry?

- A) The register operates at a lower voltage than the CPU logic
- B) The register data path crosses a clock domain boundary, risking metastability
- C) The peripheral bus register is write-only and cannot be sampled by the CPU
- D) A 10x clock frequency difference always causes data corruption regardless of synchronisation

---

**Q9.** An SoC memory map has the following layout:

| Region           | Base         | Size  |
|------------------|--------------|-------|
| Boot ROM         | 0x0000_0000  | 64 KB |
| SRAM             | 0x2000_0000  | 512 KB|
| Peripheral space | 0x4000_0000  | 1 MB  |
| External DDR     | 0x8000_0000  | 1 GB  |

The CPU attempts to read address 0x2008_0000. What is the expected response?

- A) The access returns data from the top of the SRAM region
- B) The bus fabric returns an error response because the address falls outside any mapped region
- C) The access is silently aliased to 0x2000_0000
- D) The access is redirected to the DDR region by the MMU

---

**Q10.** A glitch filter on a power-on reset (POR) signal requires the reset input to be de-asserted for a minimum of 8 consecutive fast clock cycles before releasing the system reset. What is the primary purpose of this glitch filter?

- A) To slow down the reset release to allow analog circuits such as PLLs to lock before logic runs
- B) To prevent noise or power supply transients from causing a spurious reset de-assertion that leaves clocks unstable
- C) To multiply the reset pulse width so that slower peripheral domains also receive reset
- D) To synchronise the asynchronous POR signal to the system clock domain

---

**Q11.** In a hierarchical SoC clock architecture, a "clock mux" is used to select between a slow reference clock and a fast PLL-generated clock during startup. What critical design rule must be observed when switching between these two clock sources?

- A) The mux select line must be driven from the same PLL clock that is being enabled
- B) The switch must occur while both clocks are in phase to avoid creating a glitch on the output clock
- C) The switch must be performed glitch-free, typically by ensuring the output goes low before transitioning, or using an internally synchronised mux design
- D) Switching between clock sources is only permitted when all downstream flip-flops are held in reset

---

### Advanced (Q12 -- Q15)

**Q12.** An SoC boot ROM is mapped at address 0x0000_0000. After boot, the OS needs to remap SRAM to address 0x0000_0000 so that exception vectors are located in writable memory. This is implemented by a hardware remap register. Which statement best describes the correct implementation?

- A) The remap register changes the physical address of SRAM on the die
- B) The remap register changes the base address decoding in the bus fabric so that address 0x0000_0000 routes to SRAM rather than ROM after the bit is set
- C) The remap register informs the MMU to create a virtual-to-physical mapping from 0x0000_0000 to SRAM
- D) The remap register disconnects the ROM from the bus and connects SRAM in its place using a tri-state bus

---

**Q13.** A designer must add a new 16-bit read-only status register at offset 0x10 within a peripheral's 4 KB address space. The peripheral uses a 32-bit data bus. The designer places the 16-bit register in the lower half-word (bits [15:0]) of the 32-bit word at offset 0x10. Byte addressing is supported. Which access type will correctly read the register value without a bus error, assuming byte-lane enables are respected?

- A) A 32-bit read to address (base + 0x10) returning bits [15:0] valid, bits [31:16] = zero
- B) A 16-bit read to address (base + 0x10) returning bits [15:0]
- C) A 8-bit read to address (base + 0x10) returning bits [7:0]
- D) All of A, B, and C are valid access types and all return correct data

---

**Q14.** Two independent SoC masters simultaneously initiate transactions to the same target slave. The interconnect must arbitrate between them. In a fixed-priority arbitration scheme where master A always beats master B, which of the following describes the key risk?

- A) Deadlock, where both masters block each other indefinitely
- B) Livelock, where both masters continually retry but neither completes
- C) Starvation, where master B may be indefinitely denied access if master A presents continuous back-to-back transactions
- D) Priority inversion, where master B's transaction completes before master A's

---

**Q15.** An SoC integrator discovers that the chip fails to boot reliably on a production board, but passes all simulations and bench tests. The failure is correlated with ambient temperature and supply voltage variation. Power-on reset (POR) releases correctly, but the CPU occasionally executes incorrect instructions. Which root cause is most consistent with these symptoms?

- A) A stuck-at fault on the address bus introduced during the fabrication process
- B) A setup or hold timing violation on a clock domain crossing path that only fails near process-voltage-temperature corners
- C) A mask ROM bit error in the boot code introduced during tape-out
- D) An ESD latch-up event triggered by the PCB power supply sequence



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | C      |
| 2  | B      |
| 3  | B      |
| 4  | C      |
| 5  | A      |
| 6  | C      |
| 7  | A      |
| 8  | B      |
| 9  | B      |
| 10 | B      |
| 11 | C      |
| 12 | B      |
| 13 | D      |
| 14 | C      |
| 15 | B      |

---

## Detailed Explanations

**Q1 -- Answer: C**

The bus fabric (also called an interconnect or network-on-chip) is the routing infrastructure that carries address, data, and control signals between initiators (masters) and targets (slaves). Option A describes the power distribution network. Option B describes the clock distribution network. Option D describes the function of an MMU or TLB, which performs address translation.

---

**Q2 -- Answer: B**

64 KB = 0x10000 bytes. Starting at 0x4000_0000, the range extends from 0x4000_0000 to 0x4000_0000 + 0x10000 - 1 = 0x4000_FFFF. Option A (0x7FFF offset) covers only 32 KB. Option C extends to 0x4001_FFFF, which is 128 KB. Option D lists an address lower than the base, which is incorrect.

---

**Q3 -- Answer: B**

Clock buffers (or clock tree drivers) are inserted to drive the high capacitive load presented by thousands of flip-flop clock inputs and routing wire. Without buffering, the PLL output would degrade in slew rate and the resulting slow edges increase skew, jitter, and power. Option A is wrong: the buffer does not change frequency. Option C describes a frequency multiplier, not a buffer. Option D describes a balun or differential driver, which is a separate function.

---

**Q4 -- Answer: C**

A DMA controller is a bus master because it independently initiates read and write transactions to move data between memory and peripherals without CPU involvement. SRAM, UART, and ROM are all slaves -- they respond to transactions initiated by others. In a system with DMA, the CPU is also a master, but among the options listed only the DMA controller is primarily a master by nature.

---

**Q5 -- Answer: A**

Memory-mapped I/O (MMIO) means peripheral control and status registers are assigned addresses in the processor's physical address space. Software reads and writes them using ordinary load/store instructions, just as it would access RAM. Option B refers to a FIFO backing store, which is unrelated to the addressing scheme. Option C describes interrupt routing, not I/O addressing. Option D imposes a constraint on DMA coherency, not on how I/O is addressed.

---

**Q6 -- Answer: C**

A 256 MB region starting at 0x2000_0000 occupies addresses 0x2000_0000 -- 0x2FFF_FFFF. This region is uniquely selected by address bits [31:28] = 4'b0010 (0x2). Options A and B are equivalent and both state the same thing in different notation, but only option C phrases it precisely as the hardware comparison used in decode logic. Option D (decoding 5 bits, A[31:27] = 5'b0010_0) would select only the lower 128 MB half of the region (0x2000_0000 -- 0x27FF_FFFF), not the full 256 MB.

---

**Q7 -- Answer: A**

Synchronous resets require the reset signal to be sampled at the clock edge. If the flip-flop's reset input is asynchronous-only (no synchronous reset pin), the designer must use a synchronous reset implemented by adding reset logic to the data input (D = reset ? 0 : next_state), which consumes extra logic resources. This is a real constraint in ASIC design. Option B is wrong: synchronous reset is compatible with clock gating -- if the clock is gated off, the reset holds its current value and is applied when the clock resumes, which is typically the desired behaviour. Option C is incorrect: it is the asynchronous reset release that risks metastability, not the synchronous reset itself. Option D is a vague statement that does not describe a specific hazard of synchronous reset.

---

**Q8 -- Answer: B**

When a signal crosses between two unrelated clock domains (here, 100 MHz to 1 GHz), the receiving flip-flop may sample the signal during its transition window, causing metastability. The output of the metastable flip-flop is unpredictable until it resolves. The standard solution is a two-flop synchroniser on the CDC path. Option A is incorrect: voltage domains are a separate concern and modern MMIO registers operate within the same supply domain unless level shifting is explicitly required. Option C is wrong: status registers are typically readable. Option D incorrectly states that a fixed frequency ratio always causes corruption -- what matters is the relationship between the data transition time and the receiving clock edge, not the ratio itself.

---

**Q9 -- Answer: B**

The address 0x2008_0000 is 0x80000 (512 KB) above the SRAM base. Since SRAM is only 512 KB (occupying 0x2000_0000 -- 0x2007_FFFF), the address 0x2008_0000 lies in an unmapped hole. A correctly implemented bus fabric returns a bus error (SLVERR or DECERR in AXI terminology). Option A is wrong: the SRAM top address is 0x2007_FFFF, not 0x2008_0000. Option C describes aliasing, which some simple decoders might do, but this is a design defect, not the expected correct response. Option D is wrong: the MMU translates virtual to physical addresses; the physical address 0x2008_0000 has no mapped target here.

---

**Q10 -- Answer: B**

A glitch filter on the POR de-assertion prevents brief noise spikes or supply bounce from prematurely releasing reset before clocks, PLLs, and power rails have actually stabilised. If POR were released during a supply bounce, the chip might begin executing with an unstable clock. Option A describes the function of a POR timer or a separate PLL lock detector, not the glitch filter. Option C describes clock domain pulse stretching. Option D describes a CDC synchroniser, which is a separate circuit from the glitch filter.

---

**Q11 -- Answer: C**

Switching between two unsynchronised clocks without precautions can produce a runt pulse (a transition shorter than one clock period) on the output. A runt pulse can violate the minimum pulse width requirement of downstream flip-flops and cause incorrect captures. Glitch-free clock mux designs typically use enable handshaking: they de-assert the current clock enable, wait for the current clock to complete a cycle, then assert the new clock enable, ensuring the output stays low between transitions. Option A is circular and incorrect -- the mux select cannot be driven by the clock being enabled. Option B is impractical because two independent oscillators are rarely in phase. Option D is overly restrictive; glitch-free muxes can operate without holding downstream logic in reset.

---

**Q12 -- Answer: B**

Hardware remap is implemented in the bus fabric address decode logic. Before remap, a request to address 0x0000_0000 is steered to the ROM slave. After the remap register is set, the same address is steered to SRAM instead. This is purely a routing change in the interconnect, not a physical change to the memory. Option A is impossible: the physical layout of the die does not change at runtime. Option C is wrong: the MMU handles virtual addresses; remap operates at the physical address level and does not require OS involvement. Option D describes tri-state buses, which are rarely used in modern ASIC interconnects and are not the standard mechanism for remap.

---

**Q13 -- Answer: D**

All three access types should work correctly when byte-lane enables are properly implemented. A 32-bit read to offset 0x10 returns bits [15:0] from the register and zeros (or undefined) on bits [31:16] -- a well-designed peripheral drives unused lanes to zero. A 16-bit read to offset 0x10 asserts the lower two byte enables (BE[1:0]) and returns the 16-bit value directly. A byte read to offset 0x10 asserts BE[0] and returns bits [7:0]; a read to offset 0x11 returns bits [15:8]. All are valid provided the peripheral correctly decodes byte enables. A common interview mistake is to say only 32-bit aligned accesses are valid, but AMBA protocols including AXI and AHB support sub-word accesses via byte lane strobes.

---

**Q14 -- Answer: C**

In fixed-priority arbitration, if master A produces a continuous stream of back-to-back transactions with no gaps, the arbiter always grants A. Master B never receives a grant, meaning it is starved. Starvation is the standard term for this condition. Option A (deadlock) requires a circular dependency where each master holds a resource the other needs; a simple read-to-slave scenario has no such dependency. Option B (livelock) implies both masters keep retrying; in fixed-priority arbitration, B waits silently rather than retrying. Option D (priority inversion) describes B completing before A, which is the opposite of what fixed-priority implements.

---

**Q15 -- Answer: B**

The symptoms -- works in simulation and nominal conditions, fails at temperature and voltage extremes -- are characteristic of a marginal timing path that passes at nominal PVT but violates setup or hold time at worst-case corners. CDC paths are common culprits because synchronisers require adequate metastability resolution time (MTBF), which degrades as voltage decreases or temperature increases. Option A (stuck-at fault) would produce a repeatable, temperature-independent failure visible in structural test. Option C (ROM bit error) would produce a deterministic boot failure regardless of conditions. Option D (ESD latch-up) would cause catastrophic failure, not intermittent incorrect execution, and would typically damage the device permanently.
