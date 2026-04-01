# MMU and Virtual Memory

## Overview

The Memory Management Unit is the hardware bridge between the virtual address world seen
by software and the physical address world of memory. It is a mandatory topic in any SoC
architecture interview involving RISC-V, ARM, or x86. Interviewers expect fluency in TLB
design, multi-level page table walks, page fault handling, address space identifiers,
and the specific page table formats used by RISC-V Sv32 and Sv39. Candidates working on
embedded SoC or hypervisor designs must also understand S-mode and HS-mode extensions.

---

## Concept Reference

### Virtual Memory Fundamentals

Virtual memory decouples the address space visible to a process (virtual) from the
physical layout of RAM. Every byte of virtual address space maps to either a physical
page frame, a memory-mapped device register, or nothing (unmapped = page fault).

**Benefits:**
- **Isolation:** Each process has its own virtual address space; one process cannot
  access another's physical memory without explicit sharing.
- **Overcommitment:** The sum of all virtual address spaces may exceed physical RAM;
  the OS swaps inactive pages to disk.
- **Relocation:** Programs can be compiled to run at any virtual address; physical
  placement is invisible to software.
- **Protection:** Page-level read/write/execute permissions enforced by hardware.

### Address Translation Mechanics

```
Virtual Address (VA)
        │
        │  TLB lookup (fast path, single cycle)
        │
   ┌────▼────┐
   │   TLB   │  HIT ──────────────────────────────▶ Physical Address (PA)
   └────┬────┘
        │ MISS
        │
        ▼
   Page Table Walker (hardware or software)
        │  reads page table entries from memory (slow path, N memory accesses)
        ▼
   Physical Address ──────────────────────────────▶ Physical Address (PA)
        │
        │  TLB refill (install new entry)
        ▼
   Access proceeds
```

### RISC-V Sv32 (32-bit Virtual Addresses)

Used in RV32 systems. Two-level page table. Virtual address is 32 bits; physical
address is 34 bits (supports up to 16 GB physical memory).

```
Virtual address (32 bits):
  [31:22] VPN[1] (10 bits) | [21:12] VPN[0] (10 bits) | [11:0] Page Offset (12 bits)

Page size: 4 KB (2^12)
PTE size:  4 bytes
Page table entries per table: 4 KB / 4 = 1024 = 2^10 → 10 index bits per level

Physical address (34 bits):
  [33:12] PPN (22 bits) | [11:0] Page Offset (12 bits)
```

**Two-level walk:**
```
satp register: [31] MODE=1 (Sv32 enabled) | [30:22] ASID (9 bits) | [21:0] PPN of root page table

Step 1: root_table_PA = satp.PPN * 4096
        pte_addr_L1   = root_table_PA + VPN[1] * 4
        PTE_L1        = memory_read(pte_addr_L1)   // first memory access

Step 2: next_table_PA = PTE_L1.PPN * 4096
        pte_addr_L0   = next_table_PA + VPN[0] * 4
        PTE_L0        = memory_read(pte_addr_L0)   // second memory access

PA = {PTE_L0.PPN[21:0], VirtualAddress[11:0]}
```

**PTE format (Sv32, 4 bytes):**
```
[31:10] PPN (22 bits) | [9:8] RSW | [7] D | [6] A | [5] G | [4] U | [3] X | [2] W | [1] R | [0] V

V = Valid
R = Readable
W = Writable
X = Executable
U = User-mode accessible
G = Global mapping (present in all address spaces)
A = Accessed (set by hardware on any access)
D = Dirty (set by hardware on any write)
RSW = Reserved for software use
```

**Leaf vs non-leaf PTE:**
A PTE is a leaf (mapping to a physical page) if R=1 or X=1.
A PTE is a pointer to the next level table if R=0, W=0, X=0 (and V=1).

**Sv32 superpages (4 MB):**
If the L1 PTE is a leaf (R or X set), it maps a 4 MB superpage directly.
PA = {PTE_L1.PPN[21:10], VPN[0], Offset}
The lower 10 bits of PPN in a superpage PTE must be zero.

### RISC-V Sv39 (39-bit Virtual Addresses)

Used in RV64 systems. Three-level page table. Supports up to 512 GB of virtual
address space and 56 bits of physical address.

```
Virtual address (64 bits, only [38:0] used; [63:39] must be sign-extended from bit 38):
  [38:30] VPN[2] (9 bits) | [29:21] VPN[1] (9 bits) | [20:12] VPN[0] (9 bits) | [11:0] Offset (12 bits)

PTE size: 8 bytes → entries per table = 4096 / 8 = 512 = 2^9 → 9 bits per level

satp register (RV64 Sv39):
  [63:60] MODE=8 | [59:44] ASID (16 bits) | [43:0] PPN (44 bits)
```

**Three-level walk (Sv39):**
```
Step 1: PTE_L2 = memory_read(satp.PPN * 4096 + VPN[2] * 8)   // root
Step 2: PTE_L1 = memory_read(PTE_L2.PPN * 4096 + VPN[1] * 8) // middle
Step 3: PTE_L0 = memory_read(PTE_L1.PPN * 4096 + VPN[0] * 8) // leaf

PA = {PTE_L0.PPN[53:0], VirtualAddress[11:0]}  // 56-bit PA
```

**Sv39 page sizes:**
| Level  | Leaf at | Page Size  | Typical Use              |
|--------|---------|------------|--------------------------|
| L0     | Level 2 | 4 KB       | Standard pages           |
| L1     | Level 1 | 2 MB       | Large pages (hugepages)  |
| L2     | Level 0 | 1 GB       | Gigapages (device memory) |

### TLB Architecture

A TLB (Translation Lookaside Buffer) is a small, fast, fully associative (or set-associative)
cache that stores recently used virtual-to-physical translations.

**TLB entry contents:**
```
| ASID (16 bits) | VPN (VA_bits - offset_bits) | PPN | R | W | X | U | G | V |
```

**TLB lookup:**
1. Check if the TLB holds an entry with matching (ASID, VPN) — or ASID-independent
   if G bit is set.
2. Hit: return PPN. Combine with page offset to form PA.
3. Miss: trigger a page table walk (hardware PTW or software trap).

**ASID (Address Space Identifier):**
Without ASIDs, every context switch must flush the entire TLB (all translations become
invalid because the new process has different page tables). With ASIDs, the TLB can
hold translations for multiple address spaces simultaneously. Only translations matching
the current ASID are used; others are retained for future context switches.

**TLB flush operations:**
```
SFENCE.VMA rs1=x0, rs2=x0   # Flush all TLB entries (all ASIDs, all VAs)
SFENCE.VMA rs1=VA, rs2=x0   # Flush TLB entries for address VA (all ASIDs)
SFENCE.VMA rs1=x0, rs2=ASID # Flush all TLB entries for ASID
SFENCE.VMA rs1=VA, rs2=ASID # Flush TLB entry for (VA, ASID)
```

**TLB reach:** TLB entries * Page size = address range covered without a TLB miss.
A 64-entry TLB with 4 KB pages covers 256 KB. A 2 MB hugepage TLB entry covers
8x more than 512 standard pages from a single entry.

### Protection and Fault Handling

**Page fault types:**

| Cause                          | mcause / scause Value | Description                             |
|--------------------------------|-----------------------|-----------------------------------------|
| Instruction page fault         | 12                    | Fetch from unmapped/non-executable page |
| Load page fault                | 13                    | Read from unmapped/non-readable page    |
| Store/AMO page fault           | 15                    | Write to unmapped/non-writable page     |

On a page fault:
1. Hardware saves the faulting PC in sepc, the cause in scause, the faulting VA in stval.
2. Trap to S-mode (or M-mode) handler.
3. Handler allocates a physical page, populates the PTE, executes SFENCE.VMA, and returns.

**Privilege checks on PTE access:**
- U=0: page is supervisor-only; U-mode access faults.
- W=0: write to this page faults regardless of mode.
- X=0: instruction fetch from this page faults (W^X enforcement).
- SUM bit in sstatus: when SUM=0, S-mode cannot access U-mode pages.
- MXR bit in sstatus: when MXR=1, readable pages are also executable (relaxes W^X).

---

## Tier 1 — Fundamentals

### Q1. What is the purpose of the TLB and what happens on a TLB miss?

**Answer:**

The TLB is a hardware cache of recent virtual-to-physical address translations.
Without a TLB, every memory access would require N+1 memory reads (N for the page
table walk, 1 for the actual data), where N is the number of page table levels.
With a typical DRAM latency of 50-100 ns, a three-level Sv39 walk would add 150-300 ns
to every memory access — completely unacceptable.

**TLB hit (fast path):**
The TLB is typically a fully associative structure with 32-128 entries, accessible
in 1-2 clock cycles. On a hit, the physical address is available before the first
pipeline stage that needs it (or pipelined into the memory stage). No additional
memory accesses occur.

**TLB miss (slow path):**
On a miss, a hardware page table walker (PTW) is invoked. The PTW:
1. Reads the root page table address from the satp register.
2. Performs N sequential memory reads (one per level) to traverse the page table tree.
3. Validates each PTE (checks V bit, permission bits, alignment).
4. On success: installs the translation in the TLB and re-executes the faulting access.
5. On failure (invalid PTE, permission violation): raises a page fault exception.

**PTW latency (Sv39, cache-resident page tables):**
- Best case (all PTEs in L2 cache): 3 * L2_latency ≈ 3 * 10 cycles = 30 cycles.
- Worst case (PTEs in DRAM): 3 * DRAM_latency ≈ 3 * 200 cycles = 600 cycles.

Most real systems achieve TLB hit rates of 99%+ for most workloads, so the PTW
is rarely on the critical path. The 1% miss rate with 600-cycle miss penalty
contributes: 0.01 * 600 = 6 cycles effective overhead per memory access.

---

### Q2. Explain the Sv32 address translation process step by step for the virtual address 0x80201F0C.

**Answer:**

Given: Sv32, satp.PPN = 0x80000 (root page table at physical address 0x80000000).

**Step 1: Decompose the virtual address.**
```
VA = 0x80201F0C = 1000 0000 0010 0000 0001 1111 0000 1100

VPN[1]  = VA[31:22] = 10 0000 0000 = 0x200 = 512
VPN[0]  = VA[21:12] = 00 0010 0000 = 0x020 = 32
Offset  = VA[11:0]  = 1111 0000 1100 = 0xF0C
```

**Step 2: First-level lookup.**
```
Root page table base = satp.PPN * 4096 = 0x80000000
PTE_L1 address = 0x80000000 + VPN[1] * 4 = 0x80000000 + 512 * 4 = 0x80000800
Read PTE_L1 from memory[0x80000800]

Assume PTE_L1 = 0x20001001:
  PPN[21:10] = 0x080004 (interpret as: bits[31:10] = 0x80004, i.e. PPN = 0x80004 >> 2 actually:
  PTE[31:10] = 0x80004, PPN = 0x80004 (22 bits), V=1, R=0, W=0, X=0 → non-leaf, points to L0 table
  Next table PA = PPN * 4096 = 0x80004000
```

**Step 3: Second-level lookup.**
```
L0 page table base = 0x80004000
PTE_L0 address = 0x80004000 + VPN[0] * 4 = 0x80004000 + 32 * 4 = 0x80004080
Read PTE_L0 from memory[0x80004080]

Assume PTE_L0 = 0x200000CF:
  PPN = bits[31:10] = 0x80000 (22 bits)
  D=1, A=1, U=0, X=0, W=1, R=1, V=1 → leaf PTE, read-write data page
```

**Step 4: Form physical address.**
```
PA = {PPN[21:0], Offset[11:0]}
   = {0x80000, 0xF0C}
   = 0x80000F0C
```

**Step 5: Permission check.**
- U=0 → supervisor-mode only.
- R=1 → readable.
- W=1 → writable.
- X=0 → not executable.
- If the CPU is in U-mode: page fault (U bit = 0 forbids user access).
- If the CPU is in S-mode performing a load: access permitted.

---

### Q3. What is an ASID and why does it matter for context-switch performance?

**Answer:**

An ASID (Address Space Identifier) is a hardware tag stored in each TLB entry and
in the satp register. It identifies which address space (process) a TLB entry belongs to.

**Without ASIDs:**
When the OS switches from Process A to Process B, all TLB entries from Process A
must be flushed before Process B can run, because A's virtual addresses map to
completely different physical addresses than B's. A full TLB flush means Process B
starts with a cold TLB — every memory access misses for the first few microseconds
until the TLB warms up again.

**With ASIDs:**
Each TLB entry is tagged with the ASID of the process that created it. When Process B
runs, satp.ASID is set to B's ASID. The TLB uses only entries matching the current ASID.
Process A's entries remain in the TLB, tagged with A's ASID. On the next context switch
back to A, A's TLB entries are immediately usable — no cold start.

**Impact:**
- A 64-entry TLB, fully warmed: 99% hit rate. Context switch: hit rate stays at 99%.
- A 64-entry TLB, no ASID, after context switch: 0% hit rate initially. Takes O(N_pages)
  accesses to warm back up.
- Measured benchmark improvement: 10-30% reduction in context switch overhead on
  workloads with frequent context switches (e.g., web server with many short requests).

**ASID exhaustion:**
RISC-V provides up to 16-bit ASIDs (65535 values). When all ASIDs are allocated, the
OS must recycle an ASID. Recycling requires flushing all TLB entries with the recycled
ASID (SFENCE.VMA rs2=old_ASID) before assigning it to a new process.

---

## Tier 2 — Intermediate

### Q4. How does a hardware page table walker work? Describe the PTW state machine stages for Sv39.

**Answer:**

The hardware PTW is a dedicated FSM that executes the page table walk without
firmware intervention. It is triggered on a TLB miss and runs in parallel with
the CPU pipeline (the pipeline stalls waiting for the translation to complete).

**PTW state machine (Sv39, 3 levels):**

```
IDLE
  │ TLB miss detected
  ▼
LEVEL2_REQ
  │ Issue read request to memory for root PTE
  │ Address: satp.PPN * 4096 + VPN[2] * 8
  ▼
LEVEL2_WAIT
  │ Await memory response
  │ On response: validate PTE (check V bit)
  │   If V=0 or reserved bits set: raise page fault; go to FAULT
  │   If leaf PTE (R=1 or X=1): go to TRANSLATE (1 GB gigapage)
  │   If pointer PTE (R=0, W=0, X=0): go to LEVEL1_REQ
  ▼
LEVEL1_REQ
  │ Issue read for L1 PTE
  │ Address: PTE_L2.PPN * 4096 + VPN[1] * 8
  ▼
LEVEL1_WAIT
  │ Await memory response
  │ Validate; leaf → TRANSLATE (2 MB hugepage); pointer → LEVEL0_REQ
  ▼
LEVEL0_REQ
  │ Issue read for L0 PTE
  │ Address: PTE_L1.PPN * 4096 + VPN[0] * 8
  ▼
LEVEL0_WAIT
  │ Await memory response
  │ Validate; leaf → TRANSLATE (4 KB page); pointer → FAULT (3 levels max for Sv39)
  ▼
TRANSLATE
  │ Form PA; check permissions (R, W, X, U vs current privilege)
  │ Update A/D bits in PTE if hardware A/D management enabled
  │ Install translation in TLB
  │ Signal completion to pipeline
  ▼
IDLE
```

**PTW memory access optimisation:**
The PTW issues requests to the data cache (not directly to DRAM). The OS keeps page
tables in memory accessed repeatedly, so they often reside in L2 or L3 cache.
Each PTW access hits at the L2 hit rate, significantly reducing the average PTW latency.

**A/D bit management:**
When a page is accessed, the A bit in its PTE must be set to 1 (hardware sets on access,
hardware sets D on write). The PTW performs an atomic read-modify-write to the PTE
if A or D need updating. This requires an additional memory write for the first access
to a page after A was cleared by the OS.

---

### Q5. What is the VIPT constraint on L1 cache size? How does RISC-V Sv39 interact with a VIPT L1 cache?

**Answer:**

**VIPT (Virtually Indexed, Physically Tagged)** uses virtual address bits to index
the cache (starting the tag RAM access immediately) while the TLB translates the
upper bits in parallel. This hides TLB latency from the L1 access critical path.

**The alias constraint:**
For VIPT to be safe (no aliasing — two virtual addresses that differ only in the
index bits but map to the same physical address must not produce two different L1
entries for the same physical data), the index bits must be entirely within the
page offset bits (bits below the page boundary).

```
4 KB page: page offset = bits [11:0] (12 bits)
L1 cache line: 64 bytes → offset field = bits [5:0] (6 bits)
Available index bits in page offset: [11:6] = 6 bits
Maximum sets: 2^6 = 64
Maximum L1 size (N-way): 64 sets * N ways * 64 bytes = 4 KB * N
```

**Implication for Sv39:**
Page size is 4 KB. Index bits must be within [11:0]. The physical and virtual
page offset bits [11:0] are identical (the MMU never remaps the offset). Therefore,
any address bits used for the set index that fall within [11:0] are the same in the
virtual and physical domain — no aliasing is possible.

**L1 cache size limits with VIPT (4 KB pages):**
| Associativity | Max size (no alias) |
|---------------|---------------------|
| 1-way (direct) | 4 KB               |
| 2-way          | 8 KB               |
| 4-way          | 16 KB              |
| 8-way          | 32 KB              |

**Most modern RISC-V cores** use 16-32 KB 4-way or 8-way L1 data caches with VIPT
and remain within this constraint. For larger L1 caches, either a fully physical
index is used (PIPT, requires waiting for TLB) or larger pages (2 MB hugepages extend
the constraint to 21 bits, allowing much larger caches).

---

### Q6. Explain the page table walk for a context that is running under a hypervisor. How does Sv39 two-stage translation work?

**Answer:**

When a RISC-V guest OS runs in HS-mode (virtualised) and a guest application runs
in VU-mode, memory addresses must go through two stages of translation:

**Stage 1 (VS-stage): Guest virtual → Guest physical (GVA → GPA)**
Controlled by the VS-level satp register (VS_satp). The guest OS manages this table.
Page table format: standard Sv39. The output is a guest physical address (GPA).

**Stage 2 (G-stage): Guest physical → Host physical (GPA → HPA)**
Controlled by the hypervisor's hgatp register. Only the hypervisor (HS-mode) can modify
this table. The output is the actual host physical address (HPA).

**Two-stage walk for a TLB miss:**
Every Stage 1 PTE access is itself a guest physical address — which must also go
through Stage 2 translation. For a 3-level Sv39 Stage 1 walk with a 3-level G-stage:
- Root PTE (Stage 1): address translated by Stage 2 (up to 3 memory reads).
- L1 PTE (Stage 1): address translated by Stage 2 (up to 3 memory reads).
- L0 PTE (Stage 1): address translated by Stage 2 (up to 3 memory reads).
- Data access: GPA translated by Stage 2 (up to 3 memory reads).
- **Worst case: 12 memory accesses for a single data load under two-stage translation.**

**Optimisation — joint TLB:**
Cache (GVA, VMID, ASID) → HPA translations directly. A TLB hit at the joint TLB
returns the final HPA with a single lookup, bypassing both stage table walks.
RISC-V Hext (hypervisor extension) introduces VMID (virtual machine identifier) as
an additional TLB tag to distinguish between multiple VMs.

**SFENCE under hypervisor:**
- SFENCE.VMA: flushes Stage 1 TLB entries.
- HFENCE.GVMA: flushes Stage 2 TLB entries (hypervisor only).
- HFENCE.VVMA: flushes Stage 1 TLB entries for a specific guest (hypervisor only).

---

## Tier 3 — Advanced

### Q7. How does a software-managed TLB differ from a hardware page table walker? What are the trade-offs for a RISC-V bare-metal SoC?

**Answer:**

**Hardware PTW (used by most modern RISC-V cores):**
A dedicated hardware state machine traverses the page table in hardware on a TLB miss.
The ISA specifies the exact page table format (Sv32/Sv39/Sv48), and the hardware is
hardwired to walk that format. The OS simply populates page tables in the specified
format; TLB management is automatic.

**Software-managed TLB (used by MIPS, older SPARC):**
On a TLB miss, a TLB miss exception is raised. A privileged software handler runs,
looks up the page table (any format the OS chooses), and installs the translation using
a privileged TLB write instruction. The hardware does not know the page table format.

**Trade-offs for a RISC-V bare-metal SoC:**

| Property | Hardware PTW | Software TLB |
|---|---|---|
| Miss latency | ~10-30 cycles (L2 hit) to ~600 cycles (DRAM) | 100-300 cycles minimum (trap + handler + TLB write) |
| Flexibility | Fixed to Sv32/Sv39 format | Any page table format (huge pages, inverted, etc.) |
| Hardware area | PTW state machine + page table walker buses | Smaller MMU; just TLB array + privileged write instruction |
| OS complexity | OS provides standard page tables | OS must write optimised TLB miss handlers |
| Use case | Linux, rich OS | Custom RTOS, microkernel, bare-metal with known access patterns |

**For a RISC-V bare-metal SoC:**
- If running Linux or a POSIX OS: hardware PTW is strongly preferred. The 100+ cycle
  software miss handler overhead is untenable for general-purpose code.
- If running a custom RTOS with a small, known working set that keeps TLB miss rates
  below 0.01%: software-managed TLB reduces silicon area (no PTW FSM, no PTE memory
  buses) while the overhead is acceptable.
- RISC-V does not define a software TLB mechanism in the privileged spec. All RISC-V
  implementations that support virtual memory use hardware PTW.

---

### Q8. Describe the hardware mechanisms required to support huge pages in an Sv39 TLB. How does a huge-page TLB entry affect the tag comparison?

**Answer:**

Sv39 supports three page sizes: 4 KB (leaf at L0), 2 MB (leaf at L1), 1 GB (leaf at L2).
A TLB that stores only one entry size (4 KB) cannot efficiently handle hugepages — a
single 2 MB hugepage would require 512 separate 4 KB TLB entries if mapped at the
standard size.

**TLB tag modification for huge pages:**

Standard 4 KB entry:
```
TLB tag = ASID + VPN[2] + VPN[1] + VPN[0]   (full 27-bit VPN)
Physical = PPN + offset[11:0]
```

2 MB hugepage (leaf at L1 level):
```
TLB tag = ASID + VPN[2] + VPN[1]             (18-bit VPN; VPN[0] is part of the offset)
Physical = PPN + VPN[0] + offset[11:0]        (PPN covers bits [55:21]; VPN[0]+offset covers [20:0])
```

1 GB gigapage (leaf at L0 level):
```
TLB tag = ASID + VPN[2]                       (9-bit VPN)
Physical = PPN + VPN[1] + VPN[0] + offset     (PPN covers bits [55:30])
```

**Hardware implementation — page-size field per TLB entry:**
Each TLB entry carries a 2-bit PS (page size) field:

```
PS=00: 4 KB   — compare all 27 VPN bits for tag match
PS=01: 2 MB   — compare only VPN[2:1] (18 bits); VPN[0] added to offset on hit
PS=10: 1 GB   — compare only VPN[2] (9 bits); VPN[1:0] added to offset on hit
```

**Tag comparison logic:**
```systemverilog
// PS-aware TLB hit detection
wire [8:0]  incoming_vpn2 = va[38:30];
wire [8:0]  incoming_vpn1 = va[29:21];
wire [8:0]  incoming_vpn0 = va[20:12];

wire match_vpn2 = (tlb_vpn2 == incoming_vpn2);
wire match_vpn1 = (tlb_vpn1 == incoming_vpn1);
wire match_vpn0 = (tlb_vpn0 == incoming_vpn0);

wire hit = valid && (asid_match || global) && match_vpn2 &&
           ((ps == 2'b10) ||                        // 1 GB: only VPN[2] matters
            (match_vpn1 && ((ps == 2'b01) ||         // 2 MB: VPN[2]+VPN[1]
             (match_vpn0))));                         // 4 KB: all three
```

**Hugepage benefit:** One TLB entry covers 2 MB instead of 4 KB. For a 512 MB contiguous
allocation (kernel text, large database tables, GPU frame buffers), 256 hugepage TLB
entries replace 131,072 standard entries. TLB miss rate drops to near zero for such
workloads. Linux uses hugepages (transparent hugepages, THP) automatically for
large anonymous mappings. RISC-V platforms targeting high-performance applications
should support at least 2 MB superpages in their TLB design.
