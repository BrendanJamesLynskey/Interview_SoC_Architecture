# AXI4 Full Protocol

## Overview

AXI4 (Advanced eXtensible Interface, version 4) is the highest-performance member of the ARM AMBA
bus family. It is the standard interconnect protocol for CPU subsystems, GPU memory controllers,
DMA engines, and any IP block requiring high bandwidth, low latency, or support for multiple
outstanding transactions. Understanding AXI4 in depth -- including channel architecture, burst
types, handshake rules, ordering constraints, and transaction IDs -- is a core requirement for
any SoC architecture or bus protocol interview.

```
AXI4 Channel Summary:

  Master                                          Slave
    |                                               |
    |  AW (Write Address): AWVALID/AWREADY  -----> |
    |  W  (Write Data):    WVALID/WREADY    -----> |
    |  B  (Write Response):BVALID/BREADY    <----- |
    |  AR (Read Address):  ARVALID/ARREADY  -----> |
    |  R  (Read Data):     RVALID/RREADY    <----- |
```

---

## Fundamentals

### Q1. What are the five AXI4 channels and why is each channel independent?

**Question:** Name and describe the five AXI4 channels. Explain why ARM chose to separate them
rather than use a single shared bus.

**Answer:**

| Channel | Abbreviation | Direction | Key Signals | Purpose |
|---------|-------------|-----------|-------------|---------|
| Write Address | AW | Master to Slave | AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWLOCK, AWCACHE, AWPROT, AWQOS | Conveys address and burst parameters for a write transaction |
| Write Data | W | Master to Slave | WDATA, WSTRB, WLAST | Carries write data beats; WLAST marks the final beat |
| Write Response | B | Slave to Master | BID, BRESP | Slave acknowledges write completion; error status returned here |
| Read Address | AR | Master to Slave | ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARLOCK, ARCACHE, ARPROT, ARQOS | Conveys address and burst parameters for a read transaction |
| Read Data | R | Slave to Master | RID, RDATA, RRESP, RLAST | Carries read data; RLAST marks the final beat |

**Why five independent channels?**

Three core reasons:

1. **Latency hiding through decoupling.** A master can issue many write addresses on the AW
   channel and simultaneously stream data on the W channel without waiting for any B responses.
   Deep pipelines can be kept full even when slaves have high latency.

2. **Out-of-order completion.** Each transaction carries an ID (AWID, ARID). Slaves or
   interconnects can return B and R responses in any order, as long as transactions with the
   same ID are returned in issue order. Fast SRAM can respond ahead of slow DRAM for the same
   master.

3. **Independent back-pressure.** Each channel has its own VALID/READY handshake. A slow write
   data path does not stall the read address channel. A congested slave response port does not
   block address acceptance.

**Common mistake:** Candidates assume AXI is similar to AHB with a pipelined address/data
structure. AXI is fundamentally different: there is no shared bus, and reads and writes can
proceed simultaneously on independent channel pairs.

---

### Q2. Describe the AXI4 VALID/READY handshake. What are the protocol rules?

**Question:** Explain the AXI4 handshake mechanism. What are the four rules that prevent deadlock?

**Answer:**

A transfer occurs on a channel when **both VALID and READY are asserted on the same rising clock
edge**. This applies to all five channels identically.

```
          VALID asserted by source (master on AW/W/AR; slave on B/R)
          READY asserted by destination (slave on AW/W/AR; master on B/R)

Clk:   ___|--|_|--|_|--|_|--|_|--|_|--|_
VALID: _______|------------|____________
READY: _____________|------|____________
                    ^
                    Transfer occurs here (VALID && READY on rising edge)
```

**The four handshake rules (from the AXI4 specification):**

1. **VALID must not depend on READY.** A source must assert VALID whenever it has data to send,
   regardless of whether READY is asserted. This is the most critical rule. If a source waits
   for READY before asserting VALID, and the destination waits for VALID before asserting READY,
   both stall indefinitely -- deadlock.

2. **Once VALID is asserted, it must remain asserted until READY is seen.** A source cannot
   withdraw a transaction after presenting it. The source must hold all associated signals
   (address, data, control) stable until the handshake completes.

3. **READY may be asserted at any time.** The destination may assert READY before, during, or
   after VALID is asserted. Asserting READY speculatively (before VALID) is legal and reduces
   latency to one cycle.

4. **READY may be deasserted at any time** (including while VALID is already asserted). The
   destination is permitted to withdraw readiness -- for example, if it becomes full. This is
   legal as long as a pending transaction (VALID already asserted) is not lost; the source
   holds VALID stable, so the transfer simply waits.

**Deadlock pattern to avoid:**

```systemverilog
// WRONG: VALID gated on READY (violates rule 1)
assign awvalid = awvalid_internal & awready;  // NEVER do this

// CORRECT: VALID driven independently
assign awvalid = awvalid_internal;            // driven when master has a transaction
```

---

### Q3. What are the AXI4 burst types? Explain WRAP bursts with a concrete example.

**Question:** Define FIXED, INCR, and WRAP burst types. For a WRAP4 burst starting at address
0x1C with a 4-byte transfer size, what are the four beat addresses?

**Answer:**

The burst type is encoded in AXBURST[1:0]:

| Encoding | Type | Address behaviour per beat |
|----------|------|---------------------------|
| 2'b00 | FIXED | Every beat accesses the same address; used for FIFOs and streaming registers |
| 2'b01 | INCR | Address increments by transfer size each beat; used for linear memory access |
| 2'b10 | WRAP | Address increments but wraps at a power-of-two aligned boundary |
| 2'b11 | Reserved | Do not use |

**WRAP burst mechanics:**

The wrap boundary is determined by: `transfer_size_bytes x burst_length`

This product must be a power-of-two (2, 4, 8, 16, 32, 64, 128, or 256 bytes). The starting
address modulo the boundary size gives the initial offset. The burst wraps when the incrementing
address would cross the aligned boundary.

**Worked example:**
- Start address: 0x1C
- Burst length: 4 beats (AXLEN = 3)
- Transfer size: 4 bytes (AXSIZE = 2, i.e., word)
- Wrap boundary: 4 x 4 = 16 bytes
- Aligned boundary: [0x10 ... 0x1F]

```
  Boundary base = FLOOR(0x1C / 16) x 16 = 0x10
  Beat 1: 0x1C
  Beat 2: 0x1C + 4 = 0x20 -> 0x20 >= 0x20 (boundary top exclusive), wrap -> 0x10
  Beat 3: 0x10 + 4 = 0x14
  Beat 4: 0x14 + 4 = 0x18
```

Order: 0x1C, 0x10, 0x14, 0x18

**Why WRAP exists:** Cache line fills. A CPU requesting address 0x1C in a 16-byte cache line
wants the critical word (0x1C) first, then 0x10, 0x14, 0x18 to complete the line. WRAP delivers
the requested word with minimum latency while filling the full cache line without address
re-alignment logic in the master.

---

### Q4. What are outstanding transactions and how does AXI4 support them?

**Question:** Define an outstanding transaction. How does AXI4 use transaction IDs to support
multiple outstanding transactions and out-of-order completion?

**Answer:**

An **outstanding transaction** is one for which the master has sent the address (AW or AR
accepted by the slave) but has not yet received the final response (B accepted for writes; final
R beat accepted for reads). AXI4 allows a master to issue new transactions before previous ones
complete.

**Transaction IDs (AWID, ARID, BID, RID):**

Each transaction is tagged with an ID at issue. Slaves and interconnects return responses tagged
with the same ID. This enables:

1. **Out-of-order completion:** A fast SRAM (ID=1) can return data before a slow DRAM (ID=0)
   even if DRAM was issued first.
2. **ID ordering rule:** Transactions with the **same ID** must be returned **in issue order**.
   Transactions with **different IDs** may be returned in any order.

```
Time 0:  Master issues AR ID=0  to DRAM  (100-cycle latency)
Time 1:  Master issues AR ID=1  to SRAM  (5-cycle latency)
Time 2:  Master issues AR ID=2  to Cache (2-cycle latency)

Time 4:  Cache returns  RID=2, data  (out of issue order -- legal)
Time 6:  SRAM returns   RID=1, data  (out of issue order -- legal)
Time 100: DRAM returns  RID=0, data
```

**Crossbar ID expansion:** In a multi-master system, the crossbar prepends the master port number
to each ID, ensuring globally unique IDs toward slaves and enabling correct routing of responses.

**Depth of outstanding transactions:** The maximum number of outstanding transactions a master
may have in flight is bounded by the ID space (2^ID_WIDTH) and by internal tracking structures.
Interconnect IP typically supports 4, 8, or 16 outstanding per master/slave port.

---

### Q5. Explain the AXLEN, AXSIZE, and AXBURST fields. How is the total bytes transferred calculated?

**Question:** For an AXI4 transaction with AXLEN=7, AXSIZE=3, AXBURST=INCR, what is the address
range accessed starting at 0x1000?

**Answer:**

| Field | Width | Encoding | Meaning |
|-------|-------|----------|---------|
| AXLEN | 8 bits | 0 to 255 | Burst length = AXLEN + 1 beats |
| AXSIZE | 3 bits | 0=1B, 1=2B, 2=4B, 3=8B, 4=16B, 5=32B, 6=64B, 7=128B | Bytes per beat |
| AXBURST | 2 bits | 00=FIXED, 01=INCR, 10=WRAP | Burst type |

**Rules:**
- The number of beats = AXLEN + 1 (AXLEN=0 is a single-beat, non-burst transfer)
- Each beat transfers 2^AXSIZE bytes
- Total bytes = (AXLEN + 1) x 2^AXSIZE
- For INCR bursts, the beat addresses are: start, start+size, start+2*size, ...

**Worked example:**
- Start: 0x1000
- AXLEN = 7 -> 8 beats
- AXSIZE = 3 -> 8 bytes per beat
- AXBURST = INCR

```
Total bytes = 8 x 8 = 64 bytes
Address range: 0x1000 to 0x103F

Beat 1: 0x1000
Beat 2: 0x1008
Beat 3: 0x1010
Beat 4: 0x1018
Beat 5: 0x1020
Beat 6: 0x1028
Beat 7: 0x1030
Beat 8: 0x1038 (last beat; AXLAST / WLAST asserted)
```

**AXI4 constraint:** For INCR bursts, the total bytes transferred must not cross a 4KB boundary.
(4096 / (AXLEN+1) must be >= 2^AXSIZE, or equivalently start_addr[11:0] + total_bytes <= 4096.)
This avoids a transaction targeting two different physical pages.

---

### Q6. What is the difference between BRESP values OKAY, EXOKAY, SLVERR, and DECERR?

**Question:** Define each AXI4 response code and give a hardware scenario where each would be
returned.

**Answer:**

BRESP and RRESP are 2-bit fields:

| Encoding | Name | Meaning |
|----------|------|---------|
| 2'b00 | OKAY | Transfer completed normally |
| 2'b01 | EXOKAY | Exclusive access succeeded (AXI4 only, not AXI4-Lite) |
| 2'b10 | SLVERR | Slave error: the slave exists but could not complete the transaction |
| 2'b11 | DECERR | Decode error: no slave is mapped at the target address |

**Hardware scenarios:**

- **OKAY:** A write to a read-write configuration register. Normal completion.
- **EXOKAY:** A master performed an exclusive read (ARLOCK=1) then exclusive write (AWLOCK=1).
  No other master wrote to that address range in between. The atomic operation succeeded.
- **SLVERR:** Writing to a read-only status register; accessing a peripheral in a powered-down
  power domain; a parity error in SRAM; a write that exceeds a slave's implemented address space.
- **DECERR:** A software bug causes a write to 0xDEADBEEF -- a region with no slave in the
  memory map. The interconnect's default slave returns DECERR.

**Critical design requirement:** Every AXI interconnect must implement a default slave that
covers all unmapped address space and returns DECERR. Without it, transactions to unmapped
addresses will never receive AWREADY/ARREADY, hanging the master permanently.

**Write data note:** Even when BRESP=SLVERR, the write data may or may not have been committed;
this is slave-defined. For DECERR, the data was never delivered to any slave.

---

## Intermediate

### Q7. Walk through a complete 4-beat write burst. Show the channel timing with a cycle diagram.

**Question:** Draw a cycle-by-cycle diagram of a 4-beat INCR write burst to address 0x2000
(AWLEN=3, AWSIZE=2, 32-bit data). Include back-pressure on the W channel.

**Answer:**

```
           AW Channel              W Channel                   B Channel
Cycle  AWVALID AWREADY  |  WVALID WREADY WDATA  WLAST  |  BVALID BREADY
  1      1       0      |    0      1     --      0     |    0      1
  2      1       1      |    1      1    D0        0     |    0      1    <- AW accepted
  3      0       -      |    1      0    D1        0     |    0      1    <- W stalled (slave back-pressure)
  4      -       -      |    1      1    D1        0     |    0      1    <- D1 accepted
  5      -       -      |    1      1    D2        0     |    0      1    <- D2 accepted
  6      -       -      |    1      1    D3        1     |    0      1    <- D3 accepted (WLAST)
  7      -       -      |    0      -     -        -     |    1      1    <- B accepted (BVALID=BREADY=1)
```

**Key observations:**

1. **AW accepted at cycle 2** (both AWVALID and AWREADY high). The master deasserts AWVALID
   at cycle 3; it can now issue a new write address if desired.

2. **W channel back-pressure at cycle 3** (WREADY deasserted by slave). The master holds
   WVALID and WDATA stable -- it cannot withdraw the transaction (handshake rule 2).

3. **WLAST asserted with the final beat (D3) at cycle 6.** The slave must not assert BVALID
   until WLAST is received, because only then does it know the full data payload has arrived.

4. **B channel accepted at cycle 7.** BVALID (slave) and BREADY (master) are both high. The
   master checks BRESP before considering the write committed.

5. **AW and W are independent channels.** The slave accepted AW before all W data arrived.
   This is fully legal and expected. Slaves must buffer the address if necessary.

---

### Q8. Explain AXI4 ordering rules. How does a master guarantee read-after-write ordering?

**Question:** A master issues a write to address 0x4000 with AWID=1, then immediately issues a
read to 0x4000 with ARID=2. Is the master guaranteed to read back the written data? How can it
enforce ordering?

**Answer:**

**No, the master is not guaranteed to see its own write in the subsequent read.** The AXI4
ordering model states:

1. All transactions with the **same ID** to **overlapping addresses** are returned in issue order.
2. Transactions with **different IDs** have no ordering guarantee relative to each other, even
   from the same master to the same address.

In the example: AWID=1 and ARID=2 are different IDs. The read (ARID=2) may be issued to the
slave and receive a response before the write (AWID=1) has been committed.

**Methods to enforce read-after-write ordering:**

1. **Wait for write response before issuing read.** The simplest approach: do not issue the AR
   until the corresponding B response has been accepted. This serializes the access at the cost
   of throughput.

   ```
   Issue AW+W -> Wait for B -> Issue AR -> Use R data
   ```

2. **Use the same ID for both transactions.** Issue the write with AWID=0 and the read with
   ARID=0. Because same-ID transactions are ordered, the slave is required to return responses
   in issue order. The read response will not be returned until after the write is committed.

3. **Interconnect ordering support.** Some interconnects include an ordering module that tracks
   outstanding writes and holds AR acceptance for same-address transactions until outstanding
   AW transactions complete.

**Software implication:** Software on an ARM CPU issues a DSB (Data Synchronisation Barrier)
between a write and the subsequent read to the same register. The CPU's AXI master logic drains
outstanding write transactions before issuing the next read, enforcing ordering at the
bus level.

---

### Q9. What is write data interleaving and why does AXI4 prohibit it?

**Question:** AXI3 allowed write data interleaving. AXI4 prohibits it. Explain what it was,
why it was removed, and what constraint AXI4 imposes on the W channel.

**Answer:**

**Write data interleaving (AXI3):** In AXI3, a master with multiple outstanding write
transactions could send write data beats from different transactions intermixed on the W channel.
For example, with two outstanding writes (ID=0 and ID=1), the W channel could carry:
D0_ID0, D0_ID1, D1_ID0, D1_ID1 (interleaved).

The slave had to demultiplex the W channel by ID and buffer each transaction's data separately
before committing any write. This added significant implementation complexity.

**Why AXI4 prohibits it:**

1. **Complexity:** Slaves needed per-ID write data buffers proportional to the maximum number
   of outstanding write transactions. For 16 outstanding transactions with 256-beat bursts, this
   was enormous buffer area.

2. **Ordering complexity in crossbars:** Crossbars had to track W channel interleaving per
   source and merge correctly, multiplying state machine complexity.

3. **Limited benefit:** Write data interleaving provided throughput benefit only when
   write-data sources had variable latency per beat -- rare in practice.

**AXI4 W channel constraint:** Write data beats for outstanding transactions must appear on the
W channel **in the same order that the AW channel accepted those transactions.** If AW accepted
transaction T0 then T1, all of T0's data beats must appear on W before any of T1's data beats.

```
AW channel: accepts [T0 at cycle 2] then [T1 at cycle 5]
W  channel: T0_D0, T0_D1, T0_D2 (WLAST), T1_D0, T1_D1 (WLAST)
                                  ^^^^ T1 data only starts after T0 WLAST
```

This allows slaves to implement a simple FIFO rather than ID-tagged buffers.

---

### Q10. How does AXI4 exclusive access implement an atomic read-modify-write?

**Question:** A CPU needs to implement a mutex using AXI4 exclusive access. Describe the full
sequence, including what happens when the exclusive write fails.

**Answer:**

AXI4 exclusive access implements Load-Link/Store-Conditional semantics over the bus, enabling
atomic operations without a bus LOCK that would stall all other masters.

**Hardware component: Exclusive Access Monitor (EAM)**

The interconnect or slave maintains an EAM that records: master ID, address, transfer size.
There is one record per master that can perform exclusive accesses.

**Sequence:**

```
Step 1: Exclusive Read
  Master issues AR with ARLOCK=1 (exclusive)
  Slave returns RRESP=OKAY (not EXOKAY -- EXOKAY is only for exclusive writes)
  EAM records: {master_id=0, addr=0x4000, size=4B}

Step 2: Local modification
  CPU reads data from R channel, increments value locally (e.g., mutex acquire)

Step 3: Exclusive Write
  Master issues AW with AWLOCK=1 (exclusive), same address
  EAM checks: has any other master written to 0x4000 since step 1?
    YES: BRESP=OKAY (not EXOKAY) -- write committed but exclusive sequence was interrupted
    NO:  BRESP=EXOKAY             -- write committed and exclusive sequence was uninterrupted

Step 4: Master checks BRESP
  EXOKAY: success -- mutex acquired, proceed
  OKAY:   fail    -- another master modified the location, retry from step 1
```

**Retry loop in software:**

```c
int try_lock(volatile uint32_t *mutex) {
    uint32_t old_val, new_val, result;
    do {
        old_val = __ldrex(mutex);   // exclusive read (ARLOCK=1)
        new_val = 1;                // value to write (locked)
        result  = __strex(new_val, mutex); // exclusive write (AWLOCK=1)
        // result == 0: EXOKAY (success); result == 1: OKAY (failure)
    } while (result != 0);
}
```

**Why this is better than a bus LOCK:** A LOCK signal holds the bus entirely for the duration
of the read-modify-write cycle, starving all other masters. Exclusive access only marks a
monitor; the bus is free for other transactions between the exclusive read and exclusive write.

**Common mistake:** A master must only have one exclusive access sequence in flight at a time.
A second exclusive read to a different address from the same master **clears the previous EAM
entry**, making the first exclusive write fail.

---

### Q11. How does an AXI4 register slice (skid buffer) work? Why is a simple pipeline register insufficient?

**Question:** You need to insert a pipeline register stage in an AXI4 path for timing closure.
Explain why a simple flip-flop on VALID is wrong and describe the skid buffer solution.

**Answer:**

**Why a simple register fails:**

If you register VALID with a flip-flop and also register READY:

```
Master --[FF]--> VALID_reg --> Slave
Master <--[FF]-- READY_reg <-- Slave
```

The round-trip latency is 2 cycles. At cycle N, the master presents VALID=1. At cycle N+1,
VALID_reg arrives at the slave. The slave deasserts READY at cycle N+1 (back-pressure). At
cycle N+2, READY_reg arrives back at the master. But by then, the master has already sent a
second transfer at cycle N+1 (it saw READY_reg=1 until cycle N+2). This second transfer has
no place to go -- a protocol violation.

**Skid buffer solution:**

A 1-entry skid buffer holds exactly one "in-flight" beat, absorbing the 2-cycle round-trip
latency penalty.

```
         Input Side                    Skid Entry           Output Side
Master  --> [data_in reg] ----+------> [data_skid]  ----> Slave
Master  <-- [rdy_out reg] <---+------- [skid_full]  <---- Slave READY
```

**State machine:**

```
EMPTY state (skid_full=0):
  - Pass data directly: data_out = data_in_reg
  - rdy_out to master = READY_in from slave
  - If slave deasserts READY while VALID is presented:
    - Capture data_in_reg into data_skid
    - skid_full = 1; rdy_out to master = 0

FULL state (skid_full=1):
  - Present data_skid to slave
  - rdy_out to master = 0 (stalling master)
  - When slave asserts READY:
    - data_skid is consumed
    - skid_full = 0; rdy_out to master = 1
```

**Guarantees provided:**
- Input VALID and output VALID are each registered (1 FF on each path -- timing closure).
- Input READY and output READY are each registered (1 FF on each path).
- The skid entry ensures no data is lost during the 2-cycle handshake latency.
- Maximum occupancy: 1 entry (the skid register). Modest area overhead.

**Trade-off:** Each skid buffer adds 2 cycles of round-trip latency. Deep pipelined paths
may chain multiple skid buffers, accumulating latency. Use strategically at critical timing
paths identified by static timing analysis.

---

## Advanced

### Q12. Describe the AXI4 memory attribute signals (AXCACHE). How do they interact with caches?

**Question:** Explain the AXCACHE[3:0] encoding. What does a transaction with AXCACHE=4'b0010
(Normal Non-cacheable Bufferable) mean for an interconnect with a hardware cache?

**Answer:**

AXCACHE[3:0] conveys memory type and cacheability hints. The four bits are:

| Bit | Name | Meaning when set |
|-----|------|-----------------|
| [0] | Bufferable | A write may be buffered; final destination may complete the write |
| [1] | Modifiable | Transaction may be merged, split, or have its address/size modified |
| [2] | Read-Allocate | Allocate a cache line on a read miss |
| [3] | Write-Allocate | Allocate a cache line on a write miss |

**Common encodings:**

| AXCACHE | Name | Used for |
|---------|------|----------|
| 4'b0000 | Device Non-bufferable | Device registers requiring strict ordering |
| 4'b0001 | Device Bufferable | Device registers where writes may be buffered |
| 4'b0010 | Normal Non-cacheable Bufferable | DMA bypass, streaming data |
| 4'b0011 | Normal Non-cacheable Non-bufferable | Strongly-ordered I/O |
| 4'b1110 | Write-Through Read-Allocate | Cacheable, write-through |
| 4'b1111 | Write-Back Read/Write-Allocate | Fully cacheable, write-back |

**AXCACHE=4'b0010 (Normal Non-cacheable Bufferable):**
- The transaction is to normal (non-device) memory.
- It must NOT be allocated in a cache (non-cacheable) -- so a snoop filter or system cache must
  bypass or invalidate rather than serve from cache.
- Writes MAY be buffered (bufferable) -- a write buffer in the interconnect can accept the write
  and acknowledge it before the data reaches DRAM.
- This is typical of a DMA engine transferring video frame data: it should not pollute CPU caches
  and writes can be buffered for throughput.

**Design implication:** An AXI interconnect with a system-level cache (L3 or LLC) must inspect
AXCACHE on every transaction. Non-cacheable transactions bypass the cache entirely; cacheable
transactions may be served from or allocate into the cache. Hardware coherency snoop filters
also use AXCACHE to determine whether to issue snoops.

---

### Q13. How does AXPROT work? What are the implications for TrustZone?

**Question:** Describe AXPROT[2:0]. A Secure master issues a transaction with AXPROT[1]=0 and
AXPROT[2]=0. Can it access a Non-secure peripheral? Can a Non-secure master access Secure memory?

**Answer:**

AXPROT[2:0] conveys three independent properties:

| Bit | Name | 0 = | 1 = |
|-----|------|-----|-----|
| [0] | Privilege | Unprivileged access | Privileged access |
| [1] | Security | Secure access | Non-secure access |
| [2] | Instruction | Data access | Instruction fetch |

**TrustZone interaction:**

AXPROT[1] (the NS bit) is the ARM TrustZone security attribute. Hardware address decoders
enforce access rules based on this bit:

- **Secure master (AXPROT[1]=0) accessing Non-secure peripheral:** Generally ALLOWED. Secure
  software has full visibility of both Secure and Non-secure address spaces, subject to
  the TZASC (TrustZone Address Space Controller) configuration.

- **Non-secure master (AXPROT[1]=1) accessing Secure memory:** BLOCKED by the TZASC (or
  equivalent: TrustZone Memory Adapter, NPU firewall). The TZASC inspects AXPROT[1] on every
  transaction and returns DECERR for Non-secure accesses to Secure-only regions.

**Hardware enforcement:**

```
  Non-Secure CPU --> AXPROT[1]=1 --> Interconnect --> TZASC
                                                        |
                                         NS access to Secure region?
                                                YES -> DECERR
                                                NO  -> forward to slave
```

The TZASC is a programmable firewall; Secure software configures which address ranges are
Secure-only. The configuration registers of the TZASC are themselves only accessible by Secure
masters (AXPROT[1]=0), preventing Non-secure software from reconfiguring the protection.

**Common interview question:** If a DMA engine is operated by Non-secure software, AXPROT[1]=1
must be propagated on all transactions the DMA issues. The DMA controller should expose an
AXPROT register that the CPU programs and uses directly, never allowing Non-secure software to
set AXPROT[1]=0 (which would give it Secure access via DMA).

---

### Q14. How do you calculate sustainable write bandwidth on an AXI4 interface? Include an example.

**Question:** An AXI4 interface operates at 500 MHz with a 128-bit (16-byte) data bus.
Assuming WREADY is always asserted (no back-pressure) and AWREADY has 4-cycle latency per
transaction, what is the peak and sustainable write bandwidth for 16-beat bursts?

**Answer:**

**Peak bandwidth (back-to-back data, no overhead):**

```
BW_peak = frequency x data_width_bytes
        = 500 x 10^6 x 16 bytes
        = 8 GB/s
```

**Sustainable bandwidth with transaction overhead:**

For a 16-beat burst:
- W channel is occupied for 16 cycles (data beats, no gaps since WREADY always asserted)
- AW channel: 4-cycle latency before AW is accepted (AWREADY has 4-cycle response time)
- Between bursts: 1 cycle idle (minimum)

If AW is issued in parallel with W data (pipelining AW and W channels):
- The AW latency is hidden if the master pipelines the next AW while current W data flows.
- With a single master and 1 outstanding transaction max, the next AW cannot be issued until
  the current B response is received.

**Single-outstanding case:**
```
Transaction cycle budget:
  AW phase:  4 cycles (AWREADY latency)
  W  phase:  16 cycles (16 beats at 1/cycle)
  B  phase:  2 cycles (BVALID + 1 cycle for master to accept)
  -------
  Total:     22 cycles per transaction (but AW and W overlap if AW issued before W)

With AW pipelining (AW issued simultaneously with first W beat):
  Effective: max(4, 16) + 2 = 18 cycles per 16-beat transaction
```

```
Effective BW = (16 beats x 16 bytes) / (18 cycles / 500 MHz)
             = 256 bytes / (36 ns)
             = 7.1 GB/s
```

**Multiple outstanding transactions (4 outstanding):**
```
With 4 outstanding, AW latency is fully hidden inside the 4 x 16 = 64 cycles of W data:
Throughput approaches peak 8 GB/s
```

**Design lesson:** Outstanding transaction depth is a critical bandwidth parameter. Low-latency
interconnects (cache hit paths) may only need 2-4 outstanding. High-latency paths (DRAM,
external memory) require 8-32 outstanding transactions to sustain near-peak bandwidth.
`Outstanding = Latency_cycles / Burst_length` is the key formula.

---

### Q15. What are the AXI4 QoS signals and how should a crossbar use them?

**Question:** Explain AXQOS[3:0]. How does a well-designed crossbar arbitrate between a CPU
master with AXQOS=4'hF and a background DMA master with AXQOS=4'h0 sharing the same slave port?

**Answer:**

**AXQOS[3:0] encoding:**
- A 4-bit quality-of-service hint, with 0 = lowest priority and 15 = highest priority.
- The value is **advisory**: masters assert their desired priority; the interconnect uses it
  for arbitration but is not required to guarantee any specific latency.
- Masters that do not participate in QoS drive AXQOS=4'h0 (all equal priority).

**Crossbar arbitration policy:**

A well-designed crossbar uses AXQOS to implement weighted or strict-priority arbitration at
each slave port:

```
Strict priority:
  CPU (QoS=15) always wins over DMA (QoS=0) when both have pending transactions.
  Risk: DMA starvation if CPU continuously issues transactions.

Weighted round-robin with QoS weighting:
  CPU gets 15 slots per arbitration round; DMA gets 1 slot.
  No starvation; DMA still makes progress (1/16 of bandwidth).

Urgency escalation:
  DMA QoS is initially 0. If the DMA has been stalled for N cycles,
  the crossbar escalates its effective QoS, preventing indefinite starvation.
```

**Advanced feature -- QoS virtual channels:**

Some interconnects (ARM NIC-450, Arteris FlexNoC) implement separate virtual channels per QoS
level. High-QoS transactions are placed in a higher-priority queue and bypass the lower-priority
queue entirely, providing latency isolation between traffic classes.

**Interaction with ARCACHE/AWCACHE:** Transactions marked as Device Non-bufferable
(AXCACHE=4'b0000) are frequently given the highest effective QoS regardless of AXQOS, as they
represent strongly-ordered I/O accesses that must not be delayed.

**Interview tip:** Candidates should know that QoS is a hint, not a guarantee. Real SoC QoS
design involves bandwidth allocation contracts (token buckets, credit-based flow control) that
go beyond the AXQOS field itself.

---

## Summary Reference Table

| Feature | AXI4 Full | Notes |
|---------|-----------|-------|
| Channels | 5 (AW, W, B, AR, R) | All independent with VALID/READY handshakes |
| Burst types | FIXED, INCR, WRAP | WRAP for cache line fills |
| Max burst length | 256 beats (AXLEN[7:0]) | AXI3 was 16 beats max |
| Transfer size | 1 to 128 bytes/beat | AXSIZE[2:0] |
| Write data interleaving | Prohibited | Removed in AXI4 (was AXI3 feature) |
| Outstanding transactions | Yes (limited by ID width) | Out-of-order per different IDs |
| Same-ID ordering | In-order guaranteed | All same-ID responses in issue order |
| Exclusive access | ARLOCK/AWLOCK=1 | EXOKAY response on success |
| QoS | AXQOS[3:0] | Advisory 0=lowest, 15=highest |
| Protection | AXPROT[2:0] | Privilege, Secure/NS, Instruction/Data |
| Memory type | AXCACHE[3:0] | Bufferable, Modifiable, R/W-Allocate |
| 4KB boundary rule | INCR bursts must not cross | Prevents page boundary issues |
