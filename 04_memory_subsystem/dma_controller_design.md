# DMA Controller Design

## Overview

DMA (Direct Memory Access) is one of the most practically tested topics in SoC
interviews. Any candidate working on peripheral integration, embedded Linux driver
development, or system-level SoC design must understand descriptor rings, scatter-gather
transfers, coherency handshakes, and interrupt vs polling completion models.
Interviewers frequently present a partially broken DMA driver scenario and ask the
candidate to diagnose it — understanding the hardware architecture is prerequisite.

---

## Concept Reference

### DMA Transfer Models

**Simple (register-programmed) DMA:**
A single source address, destination address, and byte count are written to the DMA
controller's registers. The controller transfers the data autonomously, then asserts
an interrupt or sets a status bit.

```
CPU writes:  SRC_ADDR = 0x80001000
             DST_ADDR = 0x90002000
             BYTE_CNT = 4096
             CTRL     = START | INT_EN
DMA runs:    Fetches from 0x80001000..0x80001FFF
             Stores to   0x90002000..0x90002FFF
DMA asserts: IRQ (transfer complete)
```

**Scatter-gather DMA:**
Instead of one contiguous transfer, the DMA reads a linked list (or ring) of
**descriptors** from memory. Each descriptor describes one segment of a transfer:
source, destination, length, control flags, and a pointer to the next descriptor.
The DMA controller fetches and executes descriptors autonomously without CPU
intervention between segments.

```
Descriptor 0 (at 0x10000):  SRC=0x81000, DST=0x91000, LEN=1024, NEXT=0x10040
Descriptor 1 (at 0x10040):  SRC=0x83000, DST=0x92000, LEN=2048, NEXT=0x10080
Descriptor 2 (at 0x10080):  SRC=0x85000, DST=0x93000, LEN=512,  NEXT=NULL, FLAGS=EOL|INT
```

The CPU loads the address of Descriptor 0 into the DMA channel's HEAD register,
then sets START. The DMA fetches all three descriptors and executes all three
transfers with one interrupt at the end.

**Why scatter-gather matters:**
Real I/O transfers are rarely contiguous. An IP packet may span multiple mbuf
(memory buffer) fragments. A file write may involve non-contiguous page-aligned
buffers. Without scatter-gather, the CPU would need to either:
1. Copy everything into one contiguous buffer (memory bandwidth waste), or
2. Program the DMA multiple times and wait for an interrupt between each segment.

Scatter-gather eliminates both the copy and the CPU overhead of re-programming.

### Descriptor Ring Architecture

A descriptor ring (also called a descriptor queue or BD ring — buffer descriptor ring)
is a circular array of fixed-size descriptors in memory. Two pointers manage the ring:
- **HEAD (hardware pointer):** The next descriptor the DMA will fetch and execute.
- **TAIL (software pointer):** The last descriptor the software has produced.

```
Ring buffer (8 descriptors, indices 0-7):

    ┌───┬───┬───┬───┬───┬───┬───┬───┐
    │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │
    └───┴───┴───┴───┴───┴───┴───┴───┘
            ▲               ▲
          HEAD             TAIL
    (DMA will fetch 2)   (SW last produced 5)

Descriptors 2, 3, 4, 5 are pending for DMA.
Descriptors 6, 7, 0, 1 are free (DMA has consumed them).
```

**Ring full condition:** (TAIL + 1) % N == HEAD → ring is full; no more descriptors
can be produced until DMA consumes at least one.

**Ring empty condition:** HEAD == TAIL → DMA has consumed everything.

**Ownership bit:**
Each descriptor contains an OWN bit:
- OWN=1 (hardware-owned): DMA is allowed to fetch and execute this descriptor.
- OWN=0 (software-owned): DMA must not touch this descriptor.

Software sets OWN=1 before making the descriptor visible to hardware. On completion,
hardware clears OWN=0 and may set STATUS bits (error flags, byte count transferred).

### DMA Channels

A DMA controller typically contains multiple independent **channels**. Each channel has:
- Its own descriptor ring (or register set for simple DMA).
- Its own state machine (IDLE, FETCH_DESC, RUNNING, DONE, ERROR).
- Its own interrupt line or a shared interrupt with per-channel status bits.
- Configurable priority (for arbitration between channels on the AXI bus).
- Configurable burst size, data width, and address increment mode.

**Channel priority and arbitration:**
When multiple channels have pending transfers, the DMA must arbitrate for the bus.
Common schemes:
- **Fixed priority:** Channel 0 > Channel 1 > ... > Channel N-1. High-priority channels
  can starve low-priority ones.
- **Round-robin:** Channels take turns in order. Fair but may violate latency requirements.
- **Weighted round-robin:** Each channel is given a bandwidth weight. A channel with
  weight=4 gets 4 bus transactions per round while a channel with weight=1 gets 1.
- **QoS-tagged:** Each channel tags its AXI transactions with a QoS value. The
  interconnect arbitrates based on QoS fields.

### Interrupt vs Polling Completion

**Interrupt-driven:**
The DMA asserts an interrupt line when a transfer (or a batch of transfers) completes.
The CPU is notified asynchronously. The interrupt handler checks the status register,
clears the interrupt, and processes the completed descriptor(s).

- CPU utilisation: low during transfer. CPU does other work.
- Interrupt latency: adds overhead (save context, run handler, restore context).
  Typically 1-5 microseconds. Acceptable for bulk I/O transfers (milliseconds).

**Polling:**
The CPU repeatedly reads the DMA status register or checks the OWN bit of the next
descriptor until completion is detected.

```c
// Polling loop
while (dma_desc[head].own == 1) {
    // spin
}
// Transfer complete
```

- CPU utilisation: 100% during polling. Wastes power.
- Latency: Near-zero reaction time once the bit clears. Appropriate for very
  short transfers (<1 microsecond) where interrupt overhead exceeds transfer time.

**Hybrid (NAPI-style):**
Start with interrupts disabled; poll in a tight loop for a bounded time; re-enable
interrupts if idle. Used in high-throughput network drivers to amortise interrupt
overhead over bursts of packets.

### DMA Coherency

DMA and CPU caches interact at two points:

**Transmit (CPU → DMA → device):**
1. CPU writes data to a buffer in cache (cache line is dirty/modified).
2. CPU instructs DMA to send the buffer.
3. If caches are not flushed, the DMA reads DRAM, which may hold stale data.
4. **Fix:** CPU must flush (clean) the cache lines covering the buffer before
   starting the DMA, ensuring dirty data is written to DRAM.

**Receive (device → DMA → memory → CPU):**
1. DMA writes received data directly to DRAM.
2. CPU reads the buffer from cache — but the cache may hold a stale copy of the
   pre-receive DRAM state (cache was filled from old DRAM contents).
3. **Fix:** CPU must invalidate (not clean) the cache lines covering the receive
   buffer after the DMA completes, forcing the next CPU read to reload from DRAM.

```
Transmit:  CPU fills buf → CPU cleans cache (flush dirty lines to DRAM)
           → DMA START   → DMA reads DRAM (correct data)

Receive:   DMA START    → DMA writes DRAM
           → DMA DONE   → CPU invalidates cache (discard stale L1/L2 lines)
                        → CPU reads DRAM (correct received data)
```

**Hardware-coherent DMA:**
Some SoC designs connect the DMA to the coherency interconnect (e.g., ARM CCI or
CHI). The DMA is a coherent master — its writes snoop the caches and either update
or invalidate cached copies. No software cache maintenance needed. Used in high-end
platforms (server SoCs). Adds latency per DMA transaction (snoop overhead) but
eliminates software complexity and bugs.

**Non-coherent DMA with IOMMU:**
The IOMMU translates DMA bus addresses (IO virtual addresses, IOVAs) to physical
addresses, providing DMA isolation (a rogue DMA device cannot access memory outside
its allocated IOVA space). The IOMMU does not provide cache coherency — software
still manages flushes and invalidations.

---

## Tier 1 — Fundamentals

### Q1. What is the difference between a simple DMA transfer and a scatter-gather DMA transfer? When is each used?

**Answer:**

**Simple DMA:** Three registers define the entire transfer: source, destination,
and byte count. The DMA moves a single contiguous block of data. The CPU must re-program
these registers and restart the DMA for each segment.

*Use case:* Memory-to-memory copy of contiguous data (e.g., clearing a framebuffer,
copying a single packet from a network buffer to a socket buffer when both are
contiguous). Simple to implement and debug.

**Scatter-gather DMA:** A linked list of descriptors in memory defines the transfer.
Each descriptor contains source address, destination address, length, flags, and a
pointer to the next descriptor. The DMA autonomously chains through the descriptor
list.

*Use case:* Any I/O involving non-contiguous memory:
- Network: A single IP packet may span 3 non-contiguous mbuf fragments. Without
  scatter-gather, the driver must memcpy everything into one buffer before transmitting.
- Storage: A disk write for a file system may scatter data across multiple non-contiguous
  page-aligned buffers (pages of a large file are rarely physically contiguous).
- Audio/video: Circular DMA with a ring of descriptors continuously streams data
  to/from a codec without CPU involvement.

**Trade-off:** Scatter-gather requires the DMA to read descriptors from memory
(each descriptor fetch is an AXI read), adding overhead per segment. For a single
large contiguous transfer, simple DMA is more efficient. For many small non-contiguous
segments, scatter-gather is superior.

---

### Q2. A DMA transfer completes but the CPU reads stale data from the receive buffer. What is the likely cause and how is it fixed?

**Answer:**

**Cause: Cache coherency violation — stale cache lines over the receive buffer.**

The sequence of events:
1. The CPU previously read from (or wrote to) the receive buffer region. This loaded
   data into the L1/L2 data cache.
2. The DMA received new data and wrote it directly to DRAM (DMA is not cache-coherent).
3. The CPU reads the receive buffer. The cache returns the stale pre-DMA data
   instead of reloading from DRAM.

The CPU never sees the new data because the cache lines are still marked valid and
were not invalidated.

**Fix: Invalidate cache lines covering the receive buffer after the DMA completes.**

```c
// Before starting DMA receive:
// Ensure the receive buffer is not dirty (no CPU writes pending)
// Optionally: invalidate before DMA starts to prevent any CPU writes during transfer
invalidate_dcache_range(recv_buf, recv_buf + recv_len);

// Start DMA receive
dma_start_receive(recv_buf, recv_len);

// Wait for DMA to complete (interrupt or polling)
wait_for_dma_complete();

// Invalidate again after DMA completes to flush any cache lines loaded
// from the (now stale) pre-DMA DRAM state
invalidate_dcache_range(recv_buf, recv_buf + recv_len);

// Now safe to read received data
process_received_data(recv_buf, recv_len);
```

**Common mistake:** Using a cache flush (clean) instead of an invalidate for the receive
path. A flush writes dirty data back to DRAM but leaves the cache line valid. The CPU
still reads from the cached (stale) version. An invalidate forces the next read to
reload from DRAM, which now holds the DMA-written data.

**Hardware fix:** Use a hardware-coherent DMA engine that participates in the cache
coherency protocol. The DMA's writes snoop and invalidate cached copies in hardware,
eliminating the need for software cache maintenance entirely.

---

### Q3. Describe the DMA descriptor ring. How does the hardware know which descriptors to process?

**Answer:**

A descriptor ring is a circular array of fixed-size descriptors allocated in
memory by software. Hardware and software share the ring through an ownership
protocol:

**Descriptor structure (typical AXI DMA):**
```
Offset 0:   SRC_ADDR    (32 or 64 bits)  — source byte address
Offset 4:   DST_ADDR    (32 or 64 bits)  — destination byte address
Offset 8:   CTRL        (32 bits)         — [31] OWN, [30] IRQ_ON_DONE, [29] EOL, [15:0] BYTE_COUNT
Offset 12:  STATUS      (32 bits)         — [31] DONE, [15] ERR, [7:0] ERROR_CODE (written by HW)
Offset 16:  NEXT_DESC   (32 or 64 bits)  — PA of next descriptor (or 0 if OWN=EOL)
```

**Ownership protocol:**
1. Software initialises descriptors: sets SRC, DST, BYTE_COUNT, FLAGS, and NEXT_DESC.
2. Software sets OWN=1 (last, to prevent hardware reading a partial descriptor).
3. Software writes TAIL register (or rings a doorbell register) to notify hardware.
4. Hardware sees OWN=1 in the descriptor at HEAD. It fetches the descriptor, executes
   the transfer, clears OWN=0, writes STATUS.DONE=1, and moves HEAD to NEXT_DESC.
5. If FLAGS.IRQ_ON_DONE is set, hardware asserts an interrupt.
6. Software reads STATUS, processes the completed transfer, and may reuse the descriptor
   (set new SRC/DST/BYTE_COUNT and set OWN=1 again).

**Critical ordering requirement:**
Software must write all descriptor fields before setting OWN=1. A memory barrier
(fence) must separate the field writes from the OWN bit write. Without the barrier,
the processor's write buffer may reorder the OWN=1 write before the other fields
reach DRAM, causing the DMA to fetch a partially-initialised descriptor.

```c
// Correct descriptor setup with memory barrier
desc->src  = src_addr;
desc->dst  = dst_addr;
desc->len  = byte_count;
desc->next = next_desc_pa;
wmb();                    // write memory barrier: drain all prior writes to DRAM
desc->ctrl = OWN_BIT | byte_count;  // OWN=1 written last
```

---

## Tier 2 — Intermediate

### Q4. Design the state machine for a DMA channel with scatter-gather support. Include states for descriptor fetch, transfer execution, and error handling.

**Answer:**

**State machine:**

```
IDLE
  │ HW sees OWN=1 at HEAD (or doorbell ring)
  ▼
FETCH_DESC
  │ Issue AXI read for descriptor at HEAD address
  │ Await AXI RDATA response
  │ Check OWN bit: if OWN=0, no descriptors → go to IDLE
  ▼
VALIDATE_DESC
  │ Check descriptor fields:
  │   - SRC address within allowed DMA range (if IOMMU/bounds checking)
  │   - DST address within allowed DMA range
  │   - BYTE_COUNT > 0 and <= max transfer size
  │ If validation fails → go to ERROR
  ▼
RUNNING
  │ Issue AXI read bursts from SRC
  │ Issue AXI write bursts to DST
  │ Count bytes transferred; check for AXI SLVERR/DECERR responses
  │ If AXI error → set ERROR_CODE, go to ERROR
  │ Continue until BYTE_COUNT bytes are transferred
  ▼
UPDATE_DESC
  │ Write STATUS.DONE=1, BYTE_COUNT_ACTUAL into descriptor (AXI write)
  │ Clear OWN=0 in descriptor (AXI write to CTRL field)
  │ Issue memory barrier (AXI write fence or AWBAR=1)
  ▼
NEXT_DESC
  │ Read NEXT_DESC field from completed descriptor
  │ If FLAGS.EOL=1 (or NEXT_DESC=NULL): last descriptor; go to COMPLETE
  │ If FLAGS.EOL=0: advance HEAD = NEXT_DESC; go to FETCH_DESC
  ▼
COMPLETE
  │ If any descriptor had IRQ_ON_DONE set: assert IRQ
  │ Go to IDLE
  ▼
ERROR (reachable from VALIDATE_DESC or RUNNING)
  │ Set channel error status register
  │ Write error code into current descriptor STATUS
  │ Assert IRQ (error interrupt, separate interrupt line or status bit)
  │ Go to IDLE (channel halted; requires software reset to restart)
```

**AXI burst optimisation in RUNNING state:**
- SRC read: issue AxBURST=INCR, AxLEN=max_burst-1 (e.g., 15 for 16-beat burst),
  AxSIZE=3 (8-byte beats). Maximise utilisation by issuing read requests ahead of
  write acceptance (pipelining).
- DST write: issue write bursts matching the read return size. Use WSTRB appropriately
  for partial bursts at the start or end of a transfer.
- Outstanding transactions: allow multiple read and write transactions to be in-flight
  simultaneously (AXI supports out-of-order responses via AXI IDs).

---

### Q5. Explain DMA channels and priority arbitration. How would you configure a 4-channel DMA for a real-time audio + bulk storage workload?

**Answer:**

**Problem statement:**
- Channel 0: Audio codec (real-time, 48 kHz, 2 channels, 32-bit = 384 KB/s).
  Deadline: each 512-byte audio buffer must be refilled within 10 ms or there is an
  audible glitch.
- Channel 1: USB storage write (bulk, 20 MB/s typical, bursty, latency-tolerant).
- Channel 2: Display framebuffer (periodic, 60 Hz, 1920x1080x4 bytes ≈ 500 MB/s).
- Channel 3: Background memcpy (low priority, no real-time requirement).

**Priority configuration:**

| Channel | Use Case       | Priority | Burst Size | Bandwidth Weight |
|---------|----------------|----------|------------|------------------|
| 0       | Audio          | Highest  | 16 bytes   | 1 (tiny bursts)  |
| 2       | Display        | High     | 256 bytes  | 8                |
| 1       | USB storage    | Medium   | 128 bytes  | 4                |
| 3       | Background     | Lowest   | 64 bytes   | 1                |

**Reasoning:**

Audio (Ch 0) needs highest priority despite being the lowest bandwidth because it
has the strictest latency requirement. The 10 ms deadline for 512 bytes means the
DMA must complete a 512-byte transfer within 10 ms — at any memory bandwidth, this
is trivially achievable. The concern is latency (not bandwidth) — if the audio DMA
is blocked behind a 256-byte display burst, the worst-case delay must still be within
the deadline. Highest priority with small burst size ensures audio is never blocked
for more than one display burst length.

Display (Ch 2) gets high priority and large burst size because it has high
bandwidth demand and the interconnect is most efficient with large bursts (reduces
overhead per byte). A 60 Hz refresh requires 500 MB/s sustained — must not be starved.

USB (Ch 1) is bursty. Medium priority with moderate burst. Weighted round-robin
ensures it gets 4 bursts for every 1 burst of the background channel.

Background (Ch 3) gets whatever bandwidth remains.

**Deadline analysis for audio:**
Worst-case latency for Ch 0 = one in-progress burst from the highest-priority
active channel before preemption. If Ch 2 is mid-burst (256 bytes at 64-bit/cycle
at 200 MHz = 4 beats at 8 bytes each = 4 cycles at 5 ns = 20 ns). Audio can always
be serviced within one display burst interval — far within the 10 ms deadline.

---

### Q6. What is an IOMMU? How does it protect a system from a rogue DMA device?

**Answer:**

An **IOMMU** (Input-Output Memory Management Unit) is a hardware unit that translates
DMA addresses (IO virtual addresses, IOVAs) issued by a device into physical memory
addresses, and enforces access permissions.

Without an IOMMU:
```
DMA device programs:  SRC_ADDR = 0x0000  (kernel code page)
DMA transfers:        Reads kernel code, writes to arbitrary physical address.
Result:               Security compromise (DMA can read/write any physical memory).
```

With an IOMMU:
```
DMA device programs:  IOVA = 0x10000
IOMMU translates:     IOVA 0x10000 → PA 0x81004000 (only if mapping exists in IOMMU table)
IOMMU enforces:       Device may only access physical memory it has been explicitly mapped to.
If IOVA not mapped:   IOMMU raises a fault; DMA transaction is aborted; CPU is notified.
```

**IOMMU page table:**
The IOMMU maintains its own page table (separate from the CPU MMU). The OS driver
calls `iommu_map(domain, iova, pa, size, flags)` to create mappings before starting
DMA. After DMA completes, `iommu_unmap(domain, iova, size)` revokes the mapping.

**DMA domains:**
Each device (or group of devices) is assigned an IOMMU domain. Two devices in
different domains cannot access each other's memory. This enables multi-tenant
SoC designs where different tenants' DMA devices are isolated from each other.

**RISC-V IOMMU:**
The RISC-V IOMMU specification (Ratified 2023) defines a standard hardware interface
for RISC-V systems. It supports:
- Two-stage translation (like the hypervisor extension — device virtual → guest physical → host physical).
- Multiple IOMMU page table formats (Sv32, Sv39, Sv48, Sv57).
- MSI remapping (interrupt virtualisation).
- Fault reporting via memory-mapped registers.

**Performance impact of IOMMU:**
IOMMU translation adds one TLB-equivalent lookup per DMA transaction. Most IOMMUs
implement an IOTLB (IO TLB) to cache recent translations. IOTLB hit: ~1-5 cycles
overhead. IOTLB miss: IOMMU page table walk, similar to a CPU PTW.

---

## Tier 3 — Advanced

### Q7. Describe how a DMA descriptor ring is managed by a Linux device driver. Include the producer-consumer model, completion interrupt handler, and the memory barriers required.

**Answer:**

**Ring management overview:**

The driver maintains three indices modulo ring_size:
- `head`: next descriptor to process (DMA side, updated by ISR).
- `tail`: next free descriptor slot (driver/TX side).
- `next`: next descriptor to submit to hardware.

```c
#define RING_SIZE 256
#define DESC_SIZE 32   // bytes per descriptor

struct dma_desc {
    u32 src_addr;
    u32 dst_addr;
    u32 ctrl;          // [31]=OWN, [15:0]=byte_count
    u32 status;        // written by hardware
    u32 next_desc_pa;  // physical address of next descriptor
    u8  pad[12];       // pad to 32 bytes for alignment
} __attribute__((aligned(32)));

struct dma_channel {
    struct dma_desc *ring;    // virtual address of descriptor ring
    dma_addr_t      ring_pa;  // physical address of descriptor ring
    int             head;     // consumer index (ISR updates)
    int             tail;     // producer index (driver/TX updates)
    spinlock_t      lock;
};
```

**Submitting a transfer (producer side):**
```c
int dma_submit(struct dma_channel *ch, u32 src, u32 dst, u16 len)
{
    int idx;
    struct dma_desc *d;

    spin_lock(&ch->lock);

    if (((ch->tail + 1) % RING_SIZE) == ch->head) {
        spin_unlock(&ch->lock);
        return -ENOBUFS;  // ring full
    }

    idx = ch->tail;
    d   = &ch->ring[idx];

    d->src_addr   = src;
    d->dst_addr   = dst;
    d->next_desc_pa = ch->ring_pa + ((idx + 1) % RING_SIZE) * DESC_SIZE;

    /*
     * Memory barrier: ensure all descriptor fields are visible to
     * DMA hardware BEFORE the OWN bit is set.
     * Without this barrier, the write-buffer may reorder the OWN
     * write ahead of src_addr/dst_addr writes.
     */
    wmb();

    d->ctrl = DMA_OWN_BIT | (u32)len;   // set OWN=1 last

    ch->tail = (ch->tail + 1) % RING_SIZE;

    /* Ring doorbell: write tail index to MMIO register */
    writel(ch->tail, ch->regs + DMA_TAIL_REG);

    spin_unlock(&ch->lock);
    return 0;
}
```

**Completion interrupt handler:**
```c
irqreturn_t dma_isr(int irq, void *dev_id)
{
    struct dma_channel *ch = dev_id;
    struct dma_desc    *d;
    u32 status;

    /* Acknowledge the interrupt */
    status = readl(ch->regs + DMA_IRQ_STATUS_REG);
    writel(status, ch->regs + DMA_IRQ_CLEAR_REG);

    spin_lock(&ch->lock);

    /* Process all completed descriptors */
    while (ch->head != ch->tail) {
        d = &ch->ring[ch->head];

        /*
         * Read memory barrier: ensure we read the hardware-written
         * STATUS and OWN fields AFTER the DMA hardware has written them.
         * Without this barrier, the CPU cache may return a pre-completion
         * stale value of d->ctrl (OWN might still appear as 1).
         */
        rmb();

        if (d->ctrl & DMA_OWN_BIT)
            break;  // hardware has not yet completed this descriptor

        /* Invalidate cache if receive path */
        dma_sync_single_for_cpu(ch->dev, d->dst_addr, d->byte_count,
                                DMA_FROM_DEVICE);

        if (d->status & DMA_ERR_BIT)
            dev_err(ch->dev, "DMA error: code=%u\n", d->status & 0xFF);
        else
            complete_transfer(d->src_addr, d->dst_addr, d->byte_count);

        ch->head = (ch->head + 1) % RING_SIZE;
    }

    spin_unlock(&ch->lock);
    return IRQ_HANDLED;
}
```

**Memory barriers summary:**
| Operation | Barrier | Reason |
|-----------|---------|--------|
| Before setting OWN=1 | `wmb()` | All desc fields must be in DRAM before DMA sees OWN=1 |
| After reading OWN=0 | `rmb()` | STATUS must be read after DMA wrote it (not from prefetch cache) |
| Before CPU reads receive buffer | `dma_sync_single_for_cpu` | Invalidates stale cache lines over receive buffer |
| Before starting DMA on transmit buffer | `dma_sync_single_for_device` | Flushes dirty CPU writes to DRAM before DMA reads |

---

### Q8. How does an AXI DMA handle address alignment and burst boundary constraints? What happens when a transfer crosses a 4 KB page boundary?

**Answer:**

**AXI 4 KB boundary restriction:**
The AXI4 protocol prohibits a single burst from crossing a 4 KB address boundary.
This aligns with page boundaries in virtual memory systems and simplifies interconnect
routing (a burst within a page is guaranteed to hit the same target slave). A DMA
controller must split any transfer that would cross a 4 KB boundary into two bursts.

**Example:**
```
Transfer: SRC=0xFFFF_0FE0, LEN=64 bytes (4 beats of 16 bytes)
Beat 0:  0xFFFF_0FE0 — OK (within page 0x...0xxx)
Beat 1:  0xFFFF_0FF0 — OK
Beat 2:  0xFFFF_1000 — CROSSES 4 KB boundary (new page 0x...1xxx) → ILLEGAL in one burst

DMA must split:
  Burst 1: SRC=0xFFFF_0FE0, LEN=32 bytes (fills to page boundary 0xFFFF_1000 - 0xFFFF_0FE0)
  Burst 2: SRC=0xFFFF_1000, LEN=32 bytes (remainder, starts at new page boundary)
```

**AXI burst length constraint:**
For INCR bursts, the maximum burst length is 256 beats (AXI4). The beat size is
AxSIZE (1/2/4/8/16/32/64/128 bytes). Maximum bytes per burst: 256 * 128 = 32 KB.
For bursts longer than 32 KB, the DMA must issue multiple AXI transactions.

**Alignment constraints for beat size:**
The start address must be naturally aligned to the beat width.

```
AxSIZE=3 (8 bytes per beat): start address must be 8-byte aligned.
AxSIZE=4 (16 bytes per beat): start address must be 16-byte aligned.
```

If the source or destination buffer is misaligned, the DMA must handle the
head and tail beats specially:
- **Unaligned head:** Issue a narrow beat (AxSIZE reduced to the alignment size)
  for the first beat, then switch to full-width beats for the remainder.
- **Unaligned tail:** Similar narrow beat at the end.
- **Alternatively:** Narrow the entire burst to match the minimum alignment, at
  the cost of lower bus utilisation.

**DMA controller implementation of boundary splitting:**

```
For each segment [SRC, SRC+LEN):
  Split at 4 KB boundaries:
    burst_start = SRC
    while (burst_start < SRC + LEN):
        page_end    = (burst_start + 4096) & ~0xFFF   // next 4 KB boundary
        burst_end   = min(SRC + LEN, page_end)
        burst_len   = burst_end - burst_start
        max_axi_len = min(burst_len, max_beat_size * 256)
        issue_axi_burst(burst_start, min(burst_len, max_axi_len))
        burst_start += min(burst_len, max_axi_len)
```

**Performance implication:**
A 1 MB transfer with a randomly-aligned start address crosses ~256 4 KB boundaries.
Each boundary requires a new AXI transaction (with AWVALID/AWREADY handshake overhead).
For an interconnect with 4-cycle address-phase overhead: 256 * 4 = 1024 cycles of
overhead on a 1 MB transfer — under 0.1% overhead at 64-byte beats. For small
transfers (128 bytes, misaligned), the boundary split may double the transaction count,
which is more significant. Buffer alignment is therefore a performance best practice
in DMA driver design.
