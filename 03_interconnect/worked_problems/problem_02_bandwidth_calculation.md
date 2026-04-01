# Problem 02: Bandwidth Calculation

## Problem Statement

You are the interconnect architect for a mobile application processor SoC. The SoC contains the following agents and their bandwidth requirements:

**Masters (traffic sources):**

| Agent | Peak read BW | Peak write BW | Notes |
|---|---|---|---|
| CPU cluster (4× A78 cores) | 40 GB/s | 10 GB/s | L2 cache miss traffic |
| GPU (Imagination DXT) | 48 GB/s | 24 GB/s | Texture + framebuffer |
| Video decoder (4K@60) | 8 GB/s | 4 GB/s | Reference frame reads + output |
| Display subsystem | 4 GB/s | 0 | Scanout from framebuffer |
| Image Signal Processor | 6 GB/s | 3 GB/s | RAW capture pipeline |
| DMA controller | 8 GB/s | 8 GB/s | Background transfers |

**Interconnect and memory configuration:**

- Interconnect: 2D mesh NoC, 256-bit links, 1 GHz operating frequency
- System cache (LLC): 8 MB unified, hit rate 40% for CPU, 60% for GPU
- DRAM: 2× LPDDR5X-8533, 64-bit channels each, total interface bandwidth = 2 × (64/8) × 8533 × 10^6 / 2 = 68.3 GB/s

**Tasks:**

**(a)** Calculate the peak aggregate bandwidth demand from all masters (read + write, total).

**(b)** Calculate the effective DRAM bandwidth demand after accounting for LLC hit rates. Determine whether the DRAM configuration is sufficient.

**(c)** The NoC links are 256 bits wide at 1 GHz. Calculate the per-link bandwidth. How many parallel links must the bisection path provide to meet the DRAM-bound traffic?

**(d)** The display subsystem has a hard real-time requirement: it must receive exactly 4 GB/s sustained to prevent display underrun. The GPU generates variable bandwidth (10–48 GB/s in bursts of up to 512 bytes). Specify a QoS and traffic shaping configuration that guarantees the display requirement without unnecessarily blocking GPU traffic.

**(e)** The video decoder must sustain 8 GB/s read and 4 GB/s write simultaneously. If the interconnect introduces 50 ns average latency, and the decoder's internal buffer is 4 KB, calculate the minimum AXI outstanding transaction count (ARLEN depth) needed to avoid buffer underrun.

---

## Solution

### Part (a): Peak Aggregate Bandwidth

**Sum all master peak demands:**

| Agent | Read (GB/s) | Write (GB/s) | Total (GB/s) |
|---|---|---|---|
| CPU cluster | 40 | 10 | 50 |
| GPU | 48 | 24 | 72 |
| Video decoder | 8 | 4 | 12 |
| Display | 4 | 0 | 4 |
| ISP | 6 | 3 | 9 |
| DMA | 8 | 8 | 16 |
| **Total** | **114** | **49** | **163** |

$$\boxed{\text{Peak aggregate bandwidth demand} = 163\ \text{GB/s}}$$

**Note:** These are peak demands. Simultaneous peak from all agents is unlikely in practice — the SoC use cases (gaming, video record, video playback) activate different subsets. However, the interconnect must sustain the peak of the dominant use case without bottlenecking.

**Dominant use case analysis:**

- Gaming: CPU (50) + GPU (72) + Display (4) = 126 GB/s
- Video record: CPU (50) + ISP (9) + Video decoder (12) + Display (4) = 75 GB/s
- Background: DMA (16) + CPU (50) = 66 GB/s

Gaming is the worst case at 126 GB/s aggregate demand.

---

### Part (b): Effective DRAM Bandwidth After LLC Filtering

**LLC hit rate effect:**

When a cache lookup hits in the LLC, the DRAM is not accessed. Traffic that hits in the LLC is absorbed:

$$\text{DRAM demand} = \text{Peak demand} \times (1 - \text{LLC hit rate})$$

**CPU cluster:**

- LLC hit rate: 40%
- DRAM demand: 50 GB/s × (1 - 0.40) = 50 × 0.60 = **30 GB/s**

**GPU:**

- LLC hit rate: 60%
- DRAM demand: 72 GB/s × (1 - 0.60) = 72 × 0.40 = **28.8 GB/s**

**Other agents (no LLC, or LLC hit rate not specified — assume 0%):**

- Video decoder: 12 GB/s × 1.0 = **12 GB/s**
- Display: 4 GB/s × 1.0 = **4 GB/s**
- ISP: 9 GB/s × 1.0 = **9 GB/s**
- DMA: 16 GB/s × 1.0 = **16 GB/s**

**Total DRAM demand (gaming scenario):**

$$\text{CPU} + \text{GPU} + \text{Display} = 30 + 28.8 + 4 = 62.8\ \text{GB/s}$$

**DRAM supply:**

$$\text{LPDDR5X-8533 bandwidth} = 2\ \text{channels} \times 64\ \text{bits} \times 8533 \times 10^6\ \text{transfers/s} / 8\ \text{bits/byte}$$

$$= 2 \times 8 \times 8.533 \times 10^9 = 136.5\ \text{Gb/s} = \mathbf{17.1\ \text{GB/s per channel}}$$

Wait — re-read problem: LPDDR5X-8533 is the data rate in MT/s. Recalculate:

$$\text{Per channel} = \frac{64\ \text{bits}}{8} \times 8533 \times 10^6\ \text{MT/s} = 8\ \text{bytes} \times 8.533 \times 10^9\ \text{T/s} = 68.3\ \text{GB/s}$$

With 2 channels (DDR, so each 64-bit channel operates double-data-rate):

$$\text{Total DRAM bandwidth} = 2 \times 68.3 / 2 = 68.3\ \text{GB/s}$$

Note: The problem statement gives total = 68.3 GB/s directly. Accept this.

**Comparison:**

| Scenario | DRAM demand (GB/s) | DRAM supply (GB/s) | Headroom |
|---|---|---|---|
| Gaming | 62.8 | 68.3 | +8.0% |
| All agents peak | 163 (pre-LLC) | 68.3 | -76% (over-demand without LLC) |
| All agents post-LLC | 99.8 × 0.6 (est.) ≈ 60 | 68.3 | +12% |

**Conclusion:**

The DRAM configuration is marginally sufficient for the gaming scenario (62.8 GB/s demand vs 68.3 GB/s supply, 8% headroom). This is tight — DRAM efficiency overhead (refresh, row activation, bank conflicts) typically reduces effective DRAM throughput to 75–85% of peak. Effective DRAM = 68.3 × 0.80 = 54.6 GB/s, which is below the 62.8 GB/s gaming demand.

**Recommendation:** The design needs either (a) a larger LLC to improve GPU hit rate from 60% to ~70% (reducing GPU DRAM demand from 28.8 to 21.6 GB/s), or (b) a third LPDDR5X channel, or (c) more aggressive LLC prefetch policies for GPU texture access patterns.

---

### Part (c): NoC Link Bandwidth and Bisection Requirements

**Per-link bandwidth:**

$$\text{Link BW} = \frac{256\ \text{bits}}{8} \times 1 \times 10^9\ \text{Hz} = 32\ \text{GB/s per link}$$

**Bisection link count required:**

The DRAM controllers are typically placed at one or two edges of the mesh. All CPU/GPU traffic must cross the bisection to reach DRAM. Using the gaming DRAM demand as the cross-bisection traffic:

$$\text{Links required} = \frac{\text{DRAM demand}}{\text{Link BW}} = \frac{62.8\ \text{GB/s}}{32\ \text{GB/s/link}} = 1.96\ \text{links}$$

$$\boxed{\text{Minimum 2 parallel bisection links required}}$$

A 4×4 mesh with DRAM controllers at the bottom row provides 4 bisection links when the cut is between rows 2 and 3. Bisection bandwidth = 4 × 32 = 128 GB/s — more than 3× the requirement, providing substantial margin.

**Mesh configuration recommendation:**

A 4×4 mesh (16 nodes) provides:
- 4 bisection links per cut dimension
- Bisection BW = 4 × 32 = 128 GB/s
- This comfortably handles 62.8 GB/s DRAM demand plus LLC-internal traffic

Place DRAM controllers at nodes (3,0) and (3,1) and (3,2) and (3,3) (bottom row), CPU cluster at top-left quadrant, GPU at top-right quadrant. This distributes traffic across both bisection directions.

---

### Part (d): Display QoS and Traffic Shaping Configuration

**Requirement:** Display subsystem must receive exactly 4 GB/s sustained, even when GPU is bursting at up to 48 GB/s with 512-byte bursts.

**Analysis of the problem:**

At 48 GB/s peak, the GPU issues a 512-byte burst every:

$$T_{burst} = \frac{512\ \text{bytes}}{48 \times 10^9\ \text{bytes/s}} = 10.7\ \text{ns}$$

The display needs 4 GB/s, which at the interconnect clock (1 GHz) and 32 GB/s per link is:

$$\text{Display link utilisation} = \frac{4}{32} = 12.5\%$$

The GPU peak link utilisation = 48/32 = 150% — meaning the GPU would need 1.5 links at peak. Since only one link is available per path, the GPU cannot sustain peak continuously; it is burst-limited by link capacity.

**QoS configuration:**

Assign QoS values:
- Display: ARQOS = 4'b1111 (highest priority, real-time class)
- GPU: ARQOS = 4'b0101 (high bandwidth class)
- All others: ARQOS proportional to their class

**Traffic shaping for GPU — token bucket:**

To ensure GPU bursts do not starve the display, apply a token bucket regulator on the GPU's path to DRAM:

$$r_{GPU} = 32 - 4 - 2 = 26\ \text{GB/s}$$

(reserving 4 GB/s for display, 2 GB/s for CPU/other, leaving 26 GB/s for GPU)

$$\text{Token rate} = \frac{26 \times 10^9}{32} = 812.5 \times 10^6\ \text{tokens/s} = 1\ \text{token per 1.23 ns}$$

At 1 GHz clock: 1 token per 1.23 clock cycles → approximately 1 token per clock cycle is the maximum practical setting (integer periods). Set token rate = 26/32 × 1 = 0.8125 tokens/cycle → issue token every 1.23 cycles (use a counter: issue token at cycles 1, 2, ..., replenish 4 tokens every 5 cycles = 4/5 = 0.8 tokens/cycle ≈ 25.6 GB/s sustained).

Burst tolerance: GPU burst size = 512 bytes = 512/32 = 16 tokens. Bucket depth = 16 tokens.

```
Token bucket parameters:
  Sustained rate:  25.6 GB/s (4 tokens per 5 cycles)
  Burst tolerance: 512 bytes (16 tokens)
  Replenishment:   4 tokens every 5 cycles (4 × 32 / 5 = 25.6 GB/s)
```

**Non-work-conserving reservation for display:**

Additionally, at the DRAM scheduler level, reserve 2 DRAM command slots out of every 16 for display traffic (12.5% = 4 GB/s / 32 GB/s). When the display has a pending request, it is served within these reserved slots, pre-empting GPU traffic:

```
DRAM slot allocation (16-slot window):
  Slot 0:    Display reserved (if pending)
  Slot 8:    Display reserved (if pending)
  Slots 1–7, 9–15: GPU/CPU/others (WRR)
```

This guarantees display gets at most 2 DRAM slots per 16 (12.5% of DRAM bandwidth = 68.3 × 0.125 = 8.5 GB/s) — well above the 4 GB/s requirement.

**Result:**

- Display: guaranteed 4 GB/s by reserved DRAM slots ✓
- GPU: throttled to 25.6 GB/s by token bucket. Peak burst of 512 bytes served immediately from token, then rate-limited. GPU performance is within DRAM capacity. ✓
- Combined demand at DRAM: Display (4) + GPU (25.6) + CPU (30) = 59.6 GB/s < 68.3 GB/s. ✓

---

### Part (e): Minimum AXI Outstanding Transaction Count for Video Decoder

**Given:**

- Video decoder read bandwidth: 8 GB/s
- Video decoder write bandwidth: 4 GB/s (independent channels)
- Interconnect latency: 50 ns average (read path)
- Internal buffer: 4 KB
- Must avoid buffer underrun (buffer never empties while waiting for data)

**Concept — bandwidth-delay product:**

To sustain a target bandwidth $B$ over a link with round-trip latency $L$, the number of bytes that must be "in flight" simultaneously (outstanding transactions) is:

$$\text{Bytes in flight} = B \times L$$

$$\text{Outstanding bytes (read)} = 8 \times 10^9\ \text{B/s} \times 50 \times 10^{-9}\ \text{s} = 400\ \text{bytes}$$

**Minimum outstanding transaction count:**

If each AXI transaction is a 16-beat burst (ARLEN = 15), each transfers:

$$16\ \text{beats} \times 16\ \text{bytes/beat} = 256\ \text{bytes per transaction}$$

(Assuming 128-bit AXI data bus = 16 bytes per beat)

$$\text{Minimum transactions outstanding} = \frac{400\ \text{bytes}}{256\ \text{bytes/transaction}} = 1.56$$

Round up:

$$\boxed{\text{Minimum 2 outstanding AXI read transactions required}}$$

**Sanity check with buffer depth:**

The internal buffer is 4 KB. With 2 outstanding transactions of 256 bytes each = 512 bytes in flight. If latency spikes to worst case (say 2× average = 100 ns):

$$\text{Bytes in flight at worst case} = 8 \times 10^9 \times 100 \times 10^{-9} = 800\ \text{bytes}$$

With 2 transactions in flight: 512 bytes < 800 bytes. The buffer would drain at the rate of 8 GB/s during the latency spike:

$$\text{Buffer drain time} = \frac{4096\ \text{bytes}}{8 \times 10^9\ \text{B/s}} = 512\ \text{ns}$$

With 512 bytes pre-fetched via outstanding transactions: the buffer is topped up 512 bytes every 50 ns. The net drain rate during a latency spike = 8 GB/s consumed - 8 GB/s delivered (assuming transactions return at the expected rate) = 0 net drain during normal operation. During a latency spike where transactions are delayed:

$$\text{Maximum buffer drain} = \text{Spike duration} \times B = 100\ \text{ns} \times 8\ \text{GB/s} = 800\ \text{bytes}$$

The 4 KB buffer absorbs up to 4096/8 = 512 ns of latency spike without underrun — well above the assumed 100 ns worst case. The 2-transaction minimum is adequate.

**Practical configuration:**

Set ARLEN = 15 (16-beat bursts, 256 bytes each) and configure the decoder DMA to maintain at least 2 outstanding read transactions at all times. Use a prefetch queue with a low-watermark: when buffer < 2 KB (< 50% full), immediately issue a new read transaction to stay ahead.

**Write path analysis:**

$$\text{Outstanding bytes (write)} = 4 \times 10^9 \times 50 \times 10^{-9} = 200\ \text{bytes}$$

With 16-beat write bursts (256 bytes each):

$$\text{Minimum outstanding writes} = \lceil 200 / 256 \rceil = 1\ \text{transaction}$$

1 outstanding write transaction is sufficient for 4 GB/s. Use AWLEN = 15 (16 beats = 256 bytes).

---

## Summary of Results

| Task | Result |
|---|---|
| Peak aggregate demand | 163 GB/s (all agents), 126 GB/s (gaming scenario) |
| DRAM demand post-LLC | 62.8 GB/s (gaming), vs 68.3 GB/s supply |
| DRAM sufficiency | Marginally insufficient (efficiency reduces supply to ~55 GB/s) |
| NoC per-link bandwidth | 32 GB/s (256-bit @ 1 GHz) |
| Bisection links required | 2 minimum; 4×4 mesh provides 4 (128 GB/s, ample margin) |
| Display QoS config | ARQOS = 0xF + 2 reserved DRAM slots per 16 |
| GPU token bucket | 25.6 GB/s sustained, 16-token (512-byte) burst |
| Video decoder outstanding | 2 read transactions (ARLEN=15), 1 write transaction |

**Key interview takeaways:**

- Always verify that interconnect bandwidth ≥ DRAM bandwidth — a fast interconnect cannot compensate for a DRAM bottleneck, but an under-provisioned interconnect can prevent reaching DRAM capacity.
- The bandwidth-delay product determines how many transactions must be outstanding to pipeline latency. For 50 ns latency and 8 GB/s, only 400 bytes of pipeline depth is needed — often surprising to candidates who expect larger numbers.
- DRAM efficiency (75–85% of peak due to refresh, row activation, bank conflicts) is a critical practical derating factor. Never assume 100% DRAM efficiency.
- Display and audio subsystems require guaranteed bandwidth (non-work-conserving reservation), not merely priority (work-conserving). Priority alone does not prevent latency spikes from bursty neighbours.
