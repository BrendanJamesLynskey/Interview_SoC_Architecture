# AXI4-Stream Protocol

## Overview

AXI4-Stream is a unidirectional, point-to-point data streaming protocol defined in the ARM
AMBA 4.0 specification. Unlike AXI4 memory-mapped interfaces, AXI4-Stream has no address
channel: data flows continuously from a source (master/producer) to a sink (slave/consumer)
using a single channel with a VALID/READY handshake and TLAST packet boundary markers.

AXI4-Stream is the standard glue for data-path IP in FPGA and SoC designs: video pipelines,
DSP filter chains, network packet processors, PCIe data engines, and HDMI transmitters all
use AXI4-Stream as their inter-block data transport.

```
AXI4-Stream dataflow:

  Producer (Master)                           Consumer (Slave)
       |                                            |
       |  TDATA, TVALID, TREADY, TLAST  -------->  |
       |  TKEEP, TSTRB, TUSER, TID, TDEST ------>  |
       |  (TREADY flows back from slave) <--------  |

  Transfer occurs when: TVALID && TREADY on rising clock edge
  Packet ends when:     TVALID && TREADY && TLAST
```

---

## Fundamentals

### Q1. What signals does AXI4-Stream define? Which are mandatory and which are optional?

**Question:** List all AXI4-Stream signals. For a simple pixel pipeline, which signals are
strictly required?

**Answer:**

| Signal | Direction | Width | Mandatory? | Purpose |
|--------|-----------|-------|-----------|---------|
| ACLK | -- | 1 | Yes | Clock; all signals sampled on rising edge |
| ARESETn | -- | 1 | Yes | Active-low synchronous or asynchronous reset |
| TVALID | Master->Slave | 1 | Yes | Source signals data on TDATA is valid |
| TREADY | Slave->Master | 1 | Recommended | Sink signals it can accept data |
| TDATA | Master->Slave | N (must be multiple of 8) | Yes | Data payload |
| TLAST | Master->Slave | 1 | Recommended | Marks last beat of a packet/frame/transaction |
| TKEEP | Master->Slave | N/8 | Optional | Byte qualifier: 1=data byte, 0=null byte |
| TSTRB | Master->Slave | N/8 | Optional | Byte type: 1=data byte, 0=position byte |
| TUSER | Master->Slave | configurable | Optional | Sideband user-defined metadata |
| TID | Master->Slave | configurable | Optional | Stream identifier (source) |
| TDEST | Master->Slave | configurable | Optional | Routing destination |

**TREADY note:** The specification technically marks TREADY as optional. If omitted, the
slave is always ready (it must consume every beat without back-pressure). In practice, TREADY
should always be included to enable flow control.

**Minimal pixel pipeline (e.g., RGB data to HDMI encoder):**
- TVALID, TREADY: handshake
- TDATA[23:0]: R[7:0], G[7:0], B[7:0]
- TLAST: end-of-line marker
- TUSER[0]: start-of-frame marker (convention in Xilinx Video IP)
- TKEEP, TID, TDEST, TSTRB: not needed for a simple point-to-point pixel stream

---

### Q2. How does the AXI4-Stream handshake work? What are the protocol rules?

**Question:** Describe when a transfer occurs on AXI4-Stream. What are the rules for TVALID
and TREADY to prevent protocol violations?

**Answer:**

**Transfer rule:** A data beat is transferred when both TVALID and TREADY are asserted on the
same rising clock edge.

```
Clk:    _|--|_|--|_|--|_|--|_|--|_|--|_|--|_
TVALID: _____|---------------------------|__
TREADY: _____________|--|___|------------|__
TDATA:  -----[-------D0--][X][----D1-----|__]
                     ^        ^
                  Transfer   Transfer
                   (beat 0)  (beat 2 -- beat 1 stalled by TREADY low)
```

**Protocol rules (directly from the AXI4-Stream specification):**

1. **TVALID must not be deasserted once asserted until TREADY is seen.** If a source asserts
   TVALID, it must hold TVALID and all associated signals (TDATA, TLAST, TKEEP, TSTRB, TUSER,
   TID, TDEST) stable until the handshake completes. A source cannot withdraw a transaction.

2. **TVALID must not depend on TREADY.** The source must assert TVALID independently of
   whether TREADY is asserted. Gating TVALID on TREADY creates a deadlock potential.

3. **TREADY may be deasserted at any time.** The sink may back-pressure the source whenever it
   cannot accept data (e.g., downstream FIFO full).

4. **All payload signals must be stable while TVALID is high and TREADY is low.** After TVALID
   is asserted, TDATA, TLAST, TKEEP, TSTRB, TUSER must not change until the beat is accepted
   (TVALID && TREADY).

**Common mistake:** Registering TREADY combinatorially from downstream logic that also depends
on TVALID creates a logic loop. TREADY should be registered or computed from state, not from
TVALID directly.

---

### Q3. What is TLAST and how is it used to define packets?

**Question:** Explain TLAST. How does a video pipeline use TLAST to mark frame boundaries?
Can a packet consist of a single beat?

**Answer:**

**TLAST** marks the last beat of a packet, frame, or transfer boundary. It is asserted by the
master simultaneously with the final TDATA beat of a logical unit. The slave uses TLAST to
determine when a complete data unit has been received.

```
Single-packet transfer (4 beats):

Clk:    _|--|_|--|_|--|_|--|_|--|_
TVALID: _____|----------------|__
TREADY: __________________________ (always 1)
TDATA:  -----[D0][D1][D2][D3]___
TLAST:  __________________|__|___
                              ^
                    End of packet
```

**Video pipeline convention (Xilinx AXI4-Stream Video IP):**

```
TUSER[0] = 1 on the FIRST beat of a frame (start-of-frame)
TLAST    = 1 on the LAST beat of each horizontal line (end-of-line)

Frame structure:
  Line 0: pixels 0..N-1, TLAST on pixel N-1
  Line 1: pixels 0..N-1, TLAST on pixel N-1
  ...
  Line H-1: pixels 0..N-1, TLAST on pixel N-1 (also end-of-frame by line count)

TUSER[0]=1 only on the very first pixel of the very first line of a new frame.
```

This convention allows downstream IP (crop, scale, overlay) to detect frame boundaries
without requiring out-of-band frame synchronisation signals.

**Single-beat packet:** Yes, a packet can be a single beat. TLAST is asserted on the only
beat (the first beat is also the last beat):

```
TVALID=1, TREADY=1, TDATA=payload, TLAST=1  -- complete single-beat packet
```

**TLAST and TKEEP:** On the last beat of a packet, TKEEP may indicate that some bytes are
null (padding). For example, if a 64-bit bus carries a payload of 5 bytes, TKEEP=8'b00011111
on the TLAST beat indicates 5 valid bytes and 3 null bytes.

---

### Q4. What is the difference between TKEEP and TSTRB?

**Question:** Explain TKEEP and TSTRB. Why does AXI4-Stream define both? When would you use
TSTRB?

**Answer:**

Both TKEEP and TSTRB are byte qualifiers with one bit per data byte:

| Signal | Bit=1 meaning | Bit=0 meaning |
|--------|--------------|---------------|
| TKEEP | Data byte: carries real payload data | Null byte: padding, no data content |
| TSTRB | Data byte: byte is a real data value | Position byte: byte occupies a position but has no data value |

**The distinction:**

- **Null byte (TKEEP=0):** The byte does not exist in the data stream. It is padding on the
  final beat of a packet. Downstream IP should discard null bytes.

- **Position byte (TSTRB=0, TKEEP=1):** The byte exists in the stream and occupies a defined
  position (e.g., a gap in a sparse format), but its value is not meaningful data. The
  position is preserved for alignment purposes.

**Relationship rule:** TSTRB[n]=1 requires TKEEP[n]=1. You cannot have a data byte without
it also being a kept byte. The combinations are:

| TKEEP[n] | TSTRB[n] | Byte type |
|----------|----------|-----------|
| 1 | 1 | Data byte (payload, matters) |
| 1 | 0 | Position byte (alignment, no value) |
| 0 | 0 | Null byte (padding, discard) |
| 0 | 1 | Illegal combination |

**When to use TSTRB:** Protocol conversion contexts where sparse data formats are needed --
for example, a PCIe TLP payload where some DWORDs are disabled by byte enables. Most video
and DSP pipelines only use TKEEP and tie TSTRB to TKEEP.

**Practical note:** In the majority of AXI4-Stream designs, TKEEP is used and TSTRB is tied
equal to TKEEP or tied all-ones. TSTRB is a rarely-used advanced feature; many IPs simply
ignore it.

---

### Q5. How does TID and TDEST support stream routing and switching?

**Question:** A switch fabric has 4 input streams and 4 output streams. How do TID and TDEST
enable the fabric to route packets? What are their widths typically?

**Answer:**

**TID (Transaction/Stream ID):**
- Identifies the source of the stream.
- Set by the stream producer (master) and propagated through intermediate IP.
- Allows a downstream IP (demultiplexer, monitor) to distinguish data from different sources
  when streams are merged onto a shared path.
- Typical width: 4-8 bits.

**TDEST (Destination):**
- Identifies the intended destination or routing target.
- Set by the stream producer and used by switches/routers to direct packets.
- A stream router reads TDEST on each beat (or on the first beat of a packet) to select the
  output port.
- Typical width: 4-8 bits.

**4x4 switch fabric operation:**

```
                    Switch Fabric
Stream 0 (TID=0) ---|              |--- Output Port 0
Stream 1 (TID=1) ---|  Arbitrate   |--- Output Port 1
Stream 2 (TID=2) ---|  on TDEST    |--- Output Port 2
Stream 3 (TID=3) ---|              |--- Output Port 3

Routing: packet with TDEST=2'b01 is forwarded to Output Port 1
         regardless of which input stream it arrived on
```

**TDEST-based router state machine:**

1. Monitor TVALID on all input ports.
2. When a packet start arrives, latch TDEST from the first beat.
3. Assert TVALID on the selected output port; back-pressure the input if output is not ready.
4. Continue forwarding until TLAST on the same input port.
5. Release the output port; arbitrate for the next packet.

**Important:** The switch must not interleave beats from different packets on the same output
port. If two input packets both target Output Port 1, the switch must complete the first packet
(wait for TLAST) before beginning to forward the second. Interleaving would corrupt the packet
boundary semantics at the receiver.

---

## Intermediate

### Q6. How do you design an AXI4-Stream width converter (upsizer)? Describe converting from 32-bit to 128-bit.

**Question:** Design a 32-to-128-bit AXI4-Stream upsizer. How does it handle TLAST? What happens
to TKEEP on the output? How many cycles does it introduce?

**Answer:**

An upsizer accumulates N narrow beats and presents them as one wide beat on the output.
For 32-bit to 128-bit: accumulate 4 input beats to produce 1 output beat.

**State machine:**

```
States: FILL[0], FILL[1], FILL[2], FILL[3]

FILL[0]: Accept input beat 0 into buf[31:0].   -> FILL[1]
FILL[1]: Accept input beat 1 into buf[63:32].  -> FILL[2]
FILL[2]: Accept input beat 2 into buf[95:64].  -> FILL[3]
FILL[3]: Accept input beat 3 into buf[127:96].
         Assert output TVALID. Wait for output TREADY.
         When accepted -> FILL[0]
```

**TLAST propagation:**

If TLAST arrives on the input before all 4 beats are accumulated (short packet), the upsizer
must:
1. Mark the output beat as the last beat (TOUTLAST=1).
2. Fill TKEEP with zeros for unused output bytes.
3. Present the partial output beat immediately.

```
Example: 3-beat input packet (bytes 0-11 of payload)
  Input beat 0: TDATA=D0, TKEEP=4'hF, TLAST=0
  Input beat 1: TDATA=D1, TKEEP=4'hF, TLAST=0
  Input beat 2: TDATA=D2, TKEEP=4'hF, TLAST=1  <- last beat

Output beat:
  TDATA = {32'h0, D2, D1, D0}      (128 bits, upper 32 bits unused)
  TKEEP = 16'h0FFF                  (bytes 0-11 valid, bytes 12-15 null)
  TLAST = 1'b1                      (propagated from input)
```

**Latency:** The upsizer introduces 3 cycles of buffering latency for a full 4-beat group
(the output is not presented until the 4th input beat is received). For a partial group
(TLAST early), output is presented as soon as TLAST arrives on the input.

**Back-pressure handling:** When the output TREADY is deasserted (downstream cannot accept
the output beat), the upsizer must hold the accumulated buffer and deassert input TREADY to
stall the upstream source.

---

### Q7. How do you design an AXI4-Stream downsizer (128-bit to 32-bit)?

**Question:** Design a 128-to-32-bit AXI4-Stream downsizer. How does it handle TKEEP to
determine how many output beats to generate?

**Answer:**

A downsizer takes one wide input beat and presents it as N narrow output beats.
For 128-to-32-bit: one input beat generates up to 4 output beats.

**State machine:**

```
States: WAIT_INPUT, EMIT[0], EMIT[1], EMIT[2], EMIT[3]

WAIT_INPUT:
  Monitor input TVALID.
  When TVALID && TREADY_in (accept input):
    Latch TDATA, TKEEP, TLAST into internal registers.
    Compute last_valid_beat = last index where TKEEP has any set bits
    (or if no TKEEP: last_beat = 3 for full 4-beat output)
    -> EMIT[0]

EMIT[beat_idx]:
  Present output:
    TDATA_out = buf[32*(beat_idx+1)-1 : 32*beat_idx]
    TKEEP_out = buf_keep[4*(beat_idx+1)-1 : 4*beat_idx]  (4 bits per output beat)
    TLAST_out = (beat_idx == last_valid_beat) && buf_tlast
    TVALID_out = 1
  When output TREADY:
    If beat_idx < last_valid_beat: -> EMIT[beat_idx+1]
    Else:                          -> WAIT_INPUT
```

**Handling TKEEP for early TLAST:**

```
Input beat:  TDATA=128'hXXXX, TKEEP=16'h00FF, TLAST=1
  Bytes 0-7 are valid (TKEEP[7:0]=8'hFF)
  Bytes 8-15 are null  (TKEEP[15:8]=8'h00)
  last_valid_beat = 1   (beat index 1 contains the last valid byte, byte 7)

Output:
  Beat 0: TDATA=D[31:0],  TKEEP=4'hF, TLAST=0
  Beat 1: TDATA=D[63:32], TKEEP=4'hF, TLAST=1  <- TLAST here because byte 7 is last
  (beats 2 and 3 are suppressed -- TKEEP was 0 for those bytes)
```

**Latency:** The downsizer introduces 0 input latency (accepts input in the same cycle it
transitions to EMIT[0]) but introduces N output cycles of serialization latency.

**Simultaneous input and output:** An efficient implementation allows the input to accept the
next input beat simultaneously with emitting the last output beat of the current input.

---

### Q8. How is AXI4-Stream used in practice in an FPGA video pipeline?

**Question:** Describe the AXI4-Stream topology for a video pipeline that takes a sensor input,
applies a 2D Gaussian blur filter, and outputs to an HDMI encoder. What TUSER/TLAST conventions
are used?

**Answer:**

**Topology:**

```
Camera (MIPI CSI-2 receiver)
    |
    | 32-bit AXI4-Stream (8-bit Bayer RGB x4 per beat)
    v
AXI4-Stream FIFO (decouples sensor clock from processing clock)
    |
    | 32-bit AXI4-Stream
    v
Color Space Converter (Bayer -> RGB24)
    | 24-bit AXI4-Stream
    v
AXI4-Stream Width Upsizer (24 -> 128 bit for DDR bandwidth efficiency)
    | 128-bit AXI4-Stream
    v
AXI4-Stream to AXI4 DMA (Frame Buffer Write to DDR)
    (frame buffer in DDR)
AXI4 DMA (Frame Buffer Read from DDR)
    | 128-bit AXI4-Stream
    v
AXI4-Stream Width Downsizer (128 -> 24 bit)
    | 24-bit AXI4-Stream
    v
2D Gaussian Blur (line buffer, 3x3 kernel)
    | 24-bit AXI4-Stream
    v
HDMI Encoder
```

**TUSER/TLAST conventions (Xilinx Video IP standard):**

```
For a 1920x1080 frame:
  - TDATA = {B[7:0], G[7:0], R[7:0], 8'h00}   (24-bit pixel + 8-bit padding)
  - TLAST = 1 on the last pixel of each horizontal line (pixel 1919 of each row)
  - TUSER[0] = 1 only on the first pixel of the first line of a new frame
  - TKEEP = 4'hF (all bytes valid -- pixels are always full-width)

Frame packet structure on the bus:
  Pixel (0,0):   TVALID=1, TDATA=pixel00, TLAST=0, TUSER[0]=1   <- SOF marker
  Pixel (1,0):   TVALID=1, TDATA=pixel10, TLAST=0, TUSER[0]=0
  ...
  Pixel (1919,0):TVALID=1, TDATA=pixelN0, TLAST=1, TUSER[0]=0   <- EOL
  Pixel (0,1):   TVALID=1, TDATA=pixel01, TLAST=0, TUSER[0]=0
  ...
  Pixel (1919,1079): TVALID=1, TDATA=pixelNN, TLAST=1, TUSER[0]=0 <- EOL, EOF
```

**2D Gaussian Blur implementation consideration:**

A 3x3 filter requires 3 line buffers (to hold 3 lines of the input frame simultaneously).
The filter kernel can only produce output once it has accumulated 3 valid lines plus 3 pixel
positions within each line. This means:

- Back-pressure (TREADY=0) is asserted by the blur block during the fill period.
- Latency = approximately 2 full lines + 1 pixel before first output pixel.
- The blur block regenerates TUSER and TLAST for the output stream based on pixel counters,
  not by passing them directly from the input stream (because of the latency offset).

---

## Advanced

### Q9. How do you build a protocol-correct AXI4-Stream register slice with one cycle of registered latency?

**Question:** Design a 1-entry skid buffer for AXI4-Stream. The requirement is: both input
TREADY and output TVALID are registered (1 FF deep). Prove that the design never drops a beat.

**Answer:**

The challenge is identical to the AXI4 register slice problem: registering both TVALID
(output) and TREADY (input) creates a 2-cycle feedback loop, but a beat may arrive at the
input side while the output side is stalled.

**Solution: 1-entry skid buffer with 2 registers**

```systemverilog
module axis_skid_buffer #(
    parameter int DATA_WIDTH = 32
) (
    input  logic                    aclk,
    input  logic                    aresetn,
    // Input (upstream)
    input  logic [DATA_WIDTH-1:0]   s_tdata,
    input  logic                    s_tvalid,
    input  logic                    s_tlast,
    output logic                    s_tready,
    // Output (downstream)
    output logic [DATA_WIDTH-1:0]   m_tdata,
    output logic                    m_tvalid,
    output logic                    m_tlast,
    input  logic                    m_tready
);
    // Primary register: what we are currently presenting to downstream
    logic [DATA_WIDTH-1:0] data_reg;
    logic                  valid_reg;
    logic                  last_reg;

    // Skid register: overflow storage when downstream stalls
    logic [DATA_WIDTH-1:0] skid_data;
    logic                  skid_last;
    logic                  skid_full;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            valid_reg  <= 1'b0;
            skid_full  <= 1'b0;
        end else begin
            if (!skid_full) begin
                // Skid is empty: primary register flows freely
                if (s_tvalid && s_tready) begin
                    // Accept input
                    data_reg  <= s_tdata;
                    last_reg  <= s_tlast;
                    valid_reg <= 1'b1;
                end else if (m_tready) begin
                    valid_reg <= 1'b0;  // output consumed, nothing new
                end
            end else begin
                // Skid has data: drain skid into primary first
                if (m_tready) begin
                    data_reg  <= skid_data;
                    last_reg  <= skid_last;
                    valid_reg <= 1'b1;
                    skid_full <= 1'b0;
                end
            end

            // Capture into skid when downstream stalls but upstream presents data
            if (!skid_full && valid_reg && !m_tready && s_tvalid) begin
                skid_data <= s_tdata;
                skid_last <= s_tlast;
                skid_full <= 1'b1;
            end
        end
    end

    // Registered outputs -- 1 FF delay on TVALID and TDATA
    assign m_tdata  = data_reg;
    assign m_tvalid = valid_reg;
    assign m_tlast  = last_reg;

    // Registered TREADY: ready when skid is empty
    assign s_tready = !skid_full;

endmodule
```

**Correctness proof sketch:**

- When skid is empty and downstream is ready: data flows straight through (latency = 1 cycle).
- When downstream stalls (m_tready=0) while valid_reg=1: any new input beat is stored in
  skid_data (skid_full=1). s_tready goes low, stalling upstream. No beats are lost.
- When downstream accepts (m_tready=1) and skid_full=1: skid drains into the primary register.
  s_tready goes high again, allowing the upstream to resume.
- Maximum occupancy: 2 entries (1 in primary register, 1 in skid). The upstream sees TREADY=0
  before a third beat could overflow.

**Latency:** 1 cycle from input to output under free-running conditions.

---

### Q10. What are the implications of AXI4-Stream for latency-sensitive pipelines like radar signal processing?

**Question:** A radar signal processing pipeline has a 100 ns latency budget from ADC sample
to detector output. The pipeline uses AXI4-Stream between 6 IP blocks. What design considerations
apply?

**Answer:**

**Latency budget analysis:**

At 500 MHz, 100 ns = 50 clock cycles. With 6 IP blocks:
- Average per-block budget: 50/6 ≈ 8 cycles
- Each AXI4-Stream register slice adds 1-2 cycles
- Each FIFO adds variable latency (typically 2-5 cycles for synchronous FIFOs)

**Key considerations:**

1. **Eliminate unnecessary register slices.** In the critical latency path, avoid register
   slices unless required for timing closure. Use combinational TREADY feedback where timing
   allows, accepting that TREADY may be in the critical path.

2. **Use zero-latency TREADY.** Combinational pass-through TREADY (not registered) achieves
   zero-stall throughput but places TREADY in the timing critical path. Balance timing vs
   latency: register only where synthesis reports a violation.

3. **Avoid unnecessary FIFOs.** AXI4-Stream FIFOs (for clock domain crossing or rate
   adaptation) add latency. If all blocks share the same clock domain, remove FIFOs from
   the critical path.

4. **Measure worst-case latency, not best-case.** Back-pressure events (TREADY=0) can
   temporarily increase latency. In a latency-bounded radar system, either:
   - Guarantee the downstream never asserts back-pressure (rate-matched pipeline).
   - Implement priority pass-through that bypasses the FIFO for latency-critical data.

5. **TLAST placement affects latency reporting.** If TLAST marks a radar pulse boundary,
   ensure the TLAST signal propagates without extra latency. Some IP blocks delay TLAST
   by one cycle relative to TDATA -- this shifts the measurement reference point.

6. **Systolic architectures.** For DSP chains (FIR, FFT), replace AXI4-Stream flow control
   with a systolic (always-valid) pipeline: TVALID is always 1, TREADY is always 1, and
   data flows every cycle. This eliminates handshake logic latency entirely, at the cost
   of requiring perfectly rate-matched stages and no dynamic back-pressure capability.

7. **Pipeline depth vs throughput.** Deeper pipelines improve clock frequency (higher
   throughput) but increase latency. For a 100 ns budget with a 500 MHz target, the pipeline
   must not exceed 50 stages total. If 6 IP blocks each require 10 pipeline stages internally,
   the latency budget is already 60 cycles -- over budget at 500 MHz.

**Design pattern for minimal latency:**

```
ADC --> [IP1] --> [IP2] --> [IP3] --> [IP4] --> [IP5] --> [IP6] --> Detector
         no       no        RS*       no        no        RS*
         FIFO     FIFO               FIFO      FIFO

RS* = register slice at half-way point (timing closure only)
No FIFOs in critical path
TVALID always 1 (systolic-style) between IP1-IP4
TREADY allowed combinational for minimum latency
```

---

## Summary Reference Table

| Feature | AXI4-Stream | Notes |
|---------|-------------|-------|
| Channels | 1 (unidirectional) | Data flows master to slave only |
| Address channel | None | No memory-mapped addressing |
| Handshake | TVALID/TREADY | Same rule: transfer on both high |
| Packet framing | TLAST | Asserted on last beat of a packet |
| Byte qualifier | TKEEP, TSTRB | TKEEP for null bytes; TSTRB for position bytes |
| Routing | TDEST | Destination for switches/routers |
| Source ID | TID | Identifies stream origin |
| Sideband | TUSER | User-defined; often SOF in video |
| Burst support | Unlimited (continuous) | No burst length field -- TLAST defines boundaries |
| Back-pressure | TREADY | Sink can stall source |
| Ordering | Inherent (single channel) | Beats are always in source order |
| Outstanding transactions | N/A | Streaming, not transaction-oriented |
| Typical use | Video, audio, DSP, PCIe, network | Any continuous data flow |
| Width conversion | Upsizer/downsizer IP | Common requirement for bus width matching |
| Register slice | Skid buffer (1 entry) | 1-cycle latency, protocol-safe |
