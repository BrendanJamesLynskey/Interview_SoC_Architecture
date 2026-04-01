# Problem 03: Coherency Scenario

## Problem Statement

A quad-core SoC uses MESI cache coherency with a snooping interconnect. Each core has a private 32 KB L1 data cache (write-back, write-allocate) with 64-byte cache lines. The system has no LLC — all accesses that miss L1 go directly to DRAM through a shared AXI bus with a central snoop controller.

**Initial state:**

All caches are cold (all lines Invalid). DRAM contains:
- Address 0x1000: value 0xAB (first byte)
- Address 0x1040: value 0xCD (first byte)

Note: 0x1000 and 0x1040 are in separate 64-byte cache lines. Address 0x1000 maps to cache set 0, 0x1040 maps to cache set 1 (no aliasing).

**Scenario — execute the following operations in sequence:**

1. Core 0 reads address 0x1000
2. Core 1 reads address 0x1000
3. Core 0 writes 0xFF to address 0x1000
4. Core 2 reads address 0x1000
5. Core 3 reads address 0x1040
6. Core 1 writes 0x11 to address 0x1040
7. Core 0 evicts its copy of address 0x1000 (cache capacity pressure)
8. Core 2 reads address 0x1000 again

**Tasks:**

**(a)** For each operation, state: (i) whether it is a cache hit or miss, (ii) the bus transaction(s) generated (if any), (iii) the final MESI state of the cache line in each relevant core's cache, and (iv) the value in DRAM after the operation.

**(b)** Identify which operations generate bus traffic (snoop broadcasts) and which are handled silently in-cache.

**(c)** After step 7 (Core 0's eviction), what is the state of the cache line for address 0x1000 across all cores and in DRAM?

**(d)** In step 8, Core 2 reads address 0x1000. Is this a hit or miss? Explain what data Core 2 reads and why.

**(e)** A design review identifies that Core 0's write in step 3 generates a BusUpgr (upgrade) rather than a full BusRdX (read-exclusive). Under what conditions is a BusUpgr sufficient? What data is transferred?

**(f)** Extend the scenario: Core 0 and Core 1 are now executing a spin-lock where both cores repeatedly read-modify-write the same lock variable at address 0x1000. Describe the coherency traffic pattern and explain why this is a performance anti-pattern. How does the interconnect respond to the repeated invalidation storms?

---

## Solution

### Part (a): Step-by-Step State Trace

**Notation:**

- Core states: M=Modified, E=Exclusive, S=Shared, I=Invalid
- Bus transactions: BusRd=read (shared intent), BusRdX=read-exclusive (write intent), BusUpgr=upgrade (already have Shared, want exclusive), BusWB=write-back (eviction of Modified line)
- DRAM[0x1000] = current value in DRAM for address 0x1000

**Initial state:**

| | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] | DRAM[0x1040] |
|---|---|---|---|---|---|---|
| | I | I | I | I | 0xAB | 0xCD |

---

**Step 1: Core 0 reads address 0x1000**

- Cache hit/miss: **Miss** (Core 0 line is Invalid)
- Bus transaction: **BusRd(0x1000)**
  - Snoop controller broadcasts to all caches: "Does anyone have 0x1000?"
  - Core 1, 2, 3 respond: No (all Invalid)
  - Snoop controller: no sharers exist → Core 0 will receive line in Exclusive state
  - DRAM supplies data: [0xAB, ...]
- Core 0 state: **E** (Exclusive — only copy, clean, matches DRAM)
- All other cores: I (unchanged)
- DRAM[0x1000]: **0xAB** (unchanged — no write occurred)

| | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] |
|---|---|---|---|---|---|
| After step 1 | **E** | I | I | I | 0xAB |

*Why Exclusive and not Shared?* The snoop controller observes no other sharer responses. The E state is an optimisation: Core 0 can silently upgrade E→M on a future write without a bus transaction.

---

**Step 2: Core 1 reads address 0x1000**

- Cache hit/miss: **Miss** (Core 1 line is Invalid)
- Bus transaction: **BusRd(0x1000)**
  - Snoop controller broadcasts to all caches
  - Core 0 responds: "I have it in Exclusive state"
  - Core 0 must downgrade: **E → S** (another sharer exists now)
  - Core 0 supplies data to Core 1 (or DRAM supplies; implementation-dependent)
  - Both Core 0 and Core 1 enter Shared state
- Core 0 state: **S** (downgraded from E)
- Core 1 state: **S** (new shared copy)
- DRAM[0x1000]: **0xAB** (unchanged — E→S transition is clean, no write-back needed)

| | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] |
|---|---|---|---|---|---|
| After step 2 | **S** | **S** | I | I | 0xAB |

*Note:* No write-back is required when downgrading from E→S because the E state guarantees the line is clean (matches DRAM). DRAM already has the correct data.

---

**Step 3: Core 0 writes 0xFF to address 0x1000**

- Cache hit/miss: **Hit** (Core 0 has the line in S state)
- Bus transaction: **BusUpgr(0x1000)** (upgrade, not full BusRdX — see part e)
  - Core 0 already has the data; it only needs to invalidate other sharers
  - Snoop controller broadcasts: "Core 0 is taking exclusive ownership of 0x1000"
  - Core 1 responds: **S → I** (invalidates its copy)
  - No data transfer: Core 0 already has the data in its cache
- Core 0: **M** (Modified — dirty, holds 0xFF in first byte)
- Core 1: **I** (invalidated)
- DRAM[0x1000]: **0xAB** (still stale — write-back has not occurred yet)

| | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] |
|---|---|---|---|---|---|
| After step 3 | **M** (0xFF) | **I** | I | I | 0xAB (stale) |

*Critical:* DRAM now holds a stale value. The only valid copy of address 0x1000 is in Core 0's cache (Modified state). Any other core reading 0x1000 must snoop Core 0 and receive the updated value from Core 0's cache — not from DRAM.

---

**Step 4: Core 2 reads address 0x1000**

- Cache hit/miss: **Miss** (Core 2 line is Invalid)
- Bus transaction: **BusRd(0x1000)**
  - Snoop controller broadcasts to all caches
  - Core 0 responds: "I have it in Modified state — I must intervene"
  - **Core 0 writes back the line to DRAM** (DRAM is updated: 0x1000 → 0xFF)
  - Core 0 supplies the data to Core 2 (may be directly, or via memory)
  - Both Core 0 and Core 2 enter Shared state
- Core 0: **S** (downgraded from M; write-back completed)
- Core 2: **S** (new shared copy with updated value 0xFF)
- DRAM[0x1000]: **0xFF** (updated by Core 0's write-back)

| | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] |
|---|---|---|---|---|---|
| After step 4 | **S** (0xFF) | I | **S** (0xFF) | I | **0xFF** |

*Key point:* This is the M→S snoop response: Core 0 writes back the dirty data, DRAM is updated, and both caches hold clean Shared copies. Core 2 reads the correct value 0xFF, not the stale 0xAB.

---

**Step 5: Core 3 reads address 0x1040**

- Cache hit/miss: **Miss** (Core 3 line for 0x1040 is Invalid)
- Address 0x1040 is a **different cache line** from 0x1000 — no interference
- Bus transaction: **BusRd(0x1040)**
  - No other cache has 0x1040 (all Invalid for this line)
  - Core 3 receives data from DRAM: [0xCD, ...]
  - Core 3 enters **E** (Exclusive — no other sharers)
- DRAM[0x1040]: **0xCD** (unchanged)

| 0x1040 line | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1040] |
|---|---|---|---|---|---|
| After step 5 | I | I | I | **E** (0xCD) | 0xCD |

*(0x1000 line unchanged from step 4)*

---

**Step 6: Core 1 writes 0x11 to address 0x1040**

- Cache hit/miss: **Miss** (Core 1 has 0x1040 Invalid)
- Bus transaction: **BusRdX(0x1040)** (read-exclusive — Core 1 needs the data AND exclusive ownership)
  - Core 3 responds: "I have it in Exclusive state"
  - Core 3 must supply data and invalidate: **E → I**
  - Core 1 receives data [0xCD, ...] and takes exclusive ownership
  - Core 1 stores 0x11, line becomes Modified
- Core 1: **M** (0x11 written)
- Core 3: **I** (invalidated)
- DRAM[0x1040]: **0xCD** (stale — Core 1's write not yet written back)

| 0x1040 line | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1040] |
|---|---|---|---|---|---|
| After step 6 | I | **M** (0x11) | I | **I** | 0xCD (stale) |

*Note:* Core 3 transitions E→I. Since E is clean (matches DRAM), Core 3 does not need to write back — it simply invalidates silently. Core 1 obtains the clean data from DRAM (since Core 3's E copy matches DRAM) and immediately writes 0x11, creating a dirty Modified copy.

---

**Step 7: Core 0 evicts its copy of address 0x1000 (cache capacity pressure)**

- Core 0's copy of 0x1000 is in state **S** (clean)
- An eviction of a Shared line requires **no bus transaction**: the line is clean (matches DRAM), so Core 0 can silently drop it without writing back
- Bus transaction: **None** (silent eviction of clean line)
- Core 0: **I** (line dropped)
- Core 2 still holds: **S** (unchanged)
- DRAM[0x1000]: **0xFF** (unchanged — was already up to date)

| 0x1000 line | Core 0 | Core 1 | Core 2 | Core 3 | DRAM[0x1000] |
|---|---|---|---|---|---|
| After step 7 | **I** | I | **S** (0xFF) | I | **0xFF** |

*Contrast with Modified eviction:* If Core 0 had been in M state at eviction, it would need to issue a **BusWB** (write-back) to update DRAM before dropping the line. Shared eviction is silent and free.

---

**Step 8: Core 2 reads address 0x1000**

- Core 2's copy: **S** (0xFF)
- Cache hit/miss: **Hit** (Core 2 already has a valid Shared copy)
- Bus transaction: **None** (served from Core 2's cache)
- Value read: **0xFF** (the correct, up-to-date value)
- No state change — Core 2 remains in S

---

### Part (b): Bus Traffic Summary

| Step | Operation | Bus Transaction | Reason |
|---|---|---|---|
| 1 | Core 0 read 0x1000 | BusRd | L1 miss; fetch from DRAM |
| 2 | Core 1 read 0x1000 | BusRd | L1 miss; Core 0 downgrades E→S |
| 3 | Core 0 write 0x1000 | BusUpgr | Hit in S; invalidate other sharers |
| 4 | Core 2 read 0x1000 | BusRd | L1 miss; Core 0 write-back M→S |
| 5 | Core 3 read 0x1040 | BusRd | L1 miss; fetch from DRAM |
| 6 | Core 1 write 0x1040 | BusRdX | L1 miss; Core 3 E→I |
| 7 | Core 0 evict 0x1000 | **None** | Silent clean eviction (S state) |
| 8 | Core 2 read 0x1000 | **None** | Hit in S; served from cache |

**Silent operations (no bus traffic):**
- Step 7: Clean (Shared) eviction
- Step 8: Read hit in Shared state

**Key observation:** 6 out of 8 operations generate bus traffic in this cold-start scenario. In steady state with a warm cache, the hit rate would be much higher and bus traffic would be dominated by sharing patterns rather than cold misses.

---

### Part (c): State of 0x1000 After Step 7

| Agent | State | Value |
|---|---|---|
| Core 0 | **Invalid** | (evicted) |
| Core 1 | Invalid | (was invalidated in step 3) |
| Core 2 | **Shared** | 0xFF |
| Core 3 | Invalid | (never had 0x1000) |
| DRAM | — | **0xFF** (correct, updated in step 4 write-back) |

The system is in a clean, consistent state: one Shared copy in Core 2, DRAM matches. No dirty data outstanding.

---

### Part (d): Core 2 Reads 0x1000 (Step 8)

**Result: Cache hit.** Core 2 holds the line in Shared state with value 0xFF. The read is served from Core 2's L1 cache with no bus transaction. Core 2 reads **0xFF**.

**Why not 0xAB?** Core 0's write in step 3 (BusUpgr) invalidated Core 1's copy. Core 0's write-back in step 4 (triggered by Core 2's BusRd) updated DRAM to 0xFF. Core 2 received the updated data (0xFF) in step 4 and has held it since. The original DRAM value 0xAB was overwritten before Core 2 received its copy.

**Why not stale?** The MESI protocol guarantees that a core in Shared state holds a copy that matches DRAM (the line is clean). Since no write has occurred to 0x1000 since step 4, Core 2's Shared copy remains valid. If a write had occurred after step 4, Core 2's copy would have been invalidated via a snoop.

---

### Part (e): BusUpgr vs BusRdX

**Conditions for BusUpgr (upgrade transaction):**

A BusUpgr is issued instead of BusRdX when the requesting core **already holds a Shared copy** of the cache line and wants to upgrade to Modified (exclusive write access). The key distinction:

- **BusRdX:** "I don't have this line; give me the data AND exclusive ownership." Data must be transferred (from DRAM or from the Modified-state cache that owns it).
- **BusUpgr:** "I already have valid data in my cache; I just need to invalidate all other sharers." No data transfer is needed — the requesting core's cached data is already current (it is in Shared state, which means it matches DRAM).

**In step 3:** Core 0 holds address 0x1000 in **Shared** state. The data in Core 0's cache matches DRAM (Shared lines are always clean). Core 0 issues BusUpgr, which tells all other sharers to invalidate. Core 1 (the only other sharer) transitions S→I. No data moves over the bus.

**Data transfer for BusUpgr:** None. The requesting core keeps its existing cached data and the upgrade transaction only carries the address and command. This is more efficient than BusRdX in the case of an upgrade from Shared.

**BusUpgr is not possible from Invalid state:** A core in I state must use BusRdX, because it does not have the data and must receive it along with exclusive ownership.

**BusUpgr optimisation in MESI vs MSI:**

In an MSI-only protocol (no E state), a write to a private (non-shared) line transitions I→M via BusRdX, which includes a data transfer. In MESI, a private line goes I→E (via BusRd confirming no other sharers), then E→M silently on the first write — no BusRdX required. This eliminates a bus transaction and data transfer for private data writes.

---

### Part (f): Spin-Lock Coherency Storm

**Scenario:** Core 0 and Core 1 execute a spin-lock on address 0x1000 (a shared lock variable, initially 0 = unlocked):

```c
// Both cores executing:
while (atomic_compare_exchange(&lock, 0, 1) != 0) { /* spin */ }
// ... critical section ...
lock = 0;  // release
```

**Coherency traffic pattern:**

The compare-and-swap (CAS) or load-linked/store-conditional (LL/SC) implementation issues a BusRdX to obtain exclusive ownership before the atomic write. Each CAS attempt generates:

```
Core 0 attempts CAS:
  BusRdX(lock_addr) → Core 0 gets line in Modified (M) state
  Core 0 reads lock value: 1 (locked)
  Core 0 fails CAS → writes lock back as 1 (no change in value)
  Core 0 retains Modified state... OR issues retry loop

Meanwhile:
  Core 1 attempts CAS:
  BusRdX(lock_addr) → snoop invalidates Core 0's M line
  Core 0: M → I (write-back occurs: DRAM updated)
  Core 1 gets line in M state
  Core 1 reads lock value: 1 (locked)
  Core 1 fails CAS → issues retry

  Core 0 attempts CAS again:
  BusRdX → snoop invalidates Core 1's M line
  Core 1: M → I (write-back)
  Core 0 gets M state again
  ...
```

**The cache line ping-pong:**

Each failed CAS by one core invalidates the other core's Modified copy, forces a write-back, and transfers the line. The write-back writes value 1 (unchanged) to DRAM on every iteration. The DRAM sees repeated writes of the same value — pure coherency overhead, no useful work.

**Bus traffic per iteration (per core):**

1 BusRdX → 1 snoop → 1 M→I transition → 1 write-back (64 bytes to DRAM) → 1 BusRdX in reply from the other core = 2 DRAM writes of 64 bytes per "round" of spinning.

At a CAS retry rate of 1 per 10 cycles (3 GHz): 300 million iterations/second × 64 bytes × 2 = 38.4 GB/s of coherency traffic — for two cores spinning on a single lock variable.

**Interconnect response:**

The snoop controller must serialise all BusRdX transactions to the same address. If both cores issue BusRdX simultaneously, one must win (the arbiter selects one). The losing core's BusRdX is NACK'd (not acknowledged) and must be retried. This retry loop is the snoop arbitration cost.

The snoop filter (if present) correctly identifies that only the current M-state owner needs to be snooped, reducing the snoop fan-out to 1. But the fundamental ping-pong remains.

**Why this is a performance anti-pattern:**

1. **DRAM bandwidth consumed by zero-value writes:** Every write-back writes 64 bytes of data that has not changed (the lock variable is 4 bytes; the remaining 60 bytes of the cache line are collateral write-back traffic).

2. **Pipeline stall depth:** Each BusRdX + write-back + data transfer takes 100–300 cycles. Both spinning cores spend this time stalled waiting for the cache line, contributing nothing useful.

3. **Bus saturation:** In a system with many spin-waiters, the snoop bus becomes saturated with BusRdX transactions, degrading performance for all other agents.

**Hardware mitigations:**

1. **Monitor/Wait (ARM WFE/SEV, x86 PAUSE + MONITOR/MWAIT):** The core enters a low-power wait state and is woken by a hardware event (the lock write). Instead of repeatedly issuing BusRdX, the core issues one BusRd to get a Shared copy, monitors the address, and does not issue BusRdX until the lock value changes.

2. **Load-before-CAS pattern:** Issue a regular read first, spin until the value appears unlocked, then attempt CAS. This keeps the line in Shared state during the spinning phase (read-only snoops, no write-backs) and only issues BusRdX when the lock appears unlocked — dramatically reducing bus traffic.

3. **Queue-based locks (MCS lock):** Each spinner waits on its own private memory location rather than a shared lock variable. No coherency traffic during spinning; only one CAS on handoff.

---

## Key Takeaways

- The M→S transition (triggered by a BusRd snoop from another core) is the most expensive coherency transition: it requires a write-back to DRAM, updating memory to the latest value before sharing.
- Silent transitions (E→M on a write, S→I on eviction, E→I on eviction) generate no bus traffic and no data movement. These are free from an interconnect bandwidth perspective.
- BusUpgr is cheaper than BusRdX: no data transfer, only invalidation broadcast. Always prefer BusUpgr when the core already holds the line in Shared state.
- Spin-locks on shared memory create pathological coherency traffic (cache line ping-pong) that can consume full DRAM bandwidth while performing no useful work. Monitor/Wait instructions or software lock algorithms (MCS, CLH) are the correct solutions.
- MESI's E state eliminates bus transactions for private data writes (E→M is silent). Without E, private data writes would require BusRdX from I→M, an unnecessary bus transaction for data that is never shared.
- After a write-back during M→S transition, DRAM is guaranteed to hold the correct value. Subsequent BusRd from another core can be served from DRAM without involving the M-state cache again.
