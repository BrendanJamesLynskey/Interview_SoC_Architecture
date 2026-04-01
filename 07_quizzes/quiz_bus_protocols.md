# Quiz: Bus Protocols

15 multiple-choice questions covering AXI4, AXI4-Lite, AXI4-Stream, AHB, APB, and CHI. Questions span three difficulty tiers. Answers with explanations are collected at the end.

---

## Instructions

Select the single best answer for each question. After completing all questions, check your answers against the answer key. For each incorrect answer, read the full explanation before moving on.

Suggested time: 25 minutes.

---

## Questions

### Fundamentals (Q1 -- Q5)

**Q1.** AXI4 uses a split-channel architecture. How many independent channels does AXI4 Full define?

- A) 2 (read and write)
- B) 3 (address, data, response)
- C) 5 (write address, write data, write response, read address, read data)
- D) 4 (read address, read data, write address, write data)

---

**Q2.** The AXI4 handshake rule states that a transfer on any channel occurs when:

- A) VALID is asserted by the sender
- B) READY is asserted by the receiver
- C) Both VALID and READY are asserted simultaneously on the same rising clock edge
- D) VALID precedes READY by at least one clock cycle

---

**Q3.** Which of the following is a key difference between AXI4-Lite and AXI4 Full?

- A) AXI4-Lite supports burst transactions; AXI4 Full does not
- B) AXI4-Lite does not support burst transactions or exclusive accesses; AXI4 Full supports both
- C) AXI4-Lite uses a 64-bit data bus; AXI4 Full uses a 32-bit bus
- D) AXI4-Lite omits the write response channel; AXI4 Full includes it

---

**Q4.** In an AXI4-Stream transaction, which signal indicates that the current transfer is the last beat of a packet?

- A) TVALID
- B) TREADY
- C) TLAST
- D) TKEEP

---

**Q5.** The APB (Advanced Peripheral Bus) protocol from AMBA is described as:

- A) A high-performance pipelined bus suitable for processors and DMA controllers
- B) A simple, low-power, non-pipelined bus for low-bandwidth peripheral registers
- C) A coherent interconnect protocol for multi-core cache management
- D) A point-to-point serial protocol for off-chip communication

---

### Intermediate (Q6 -- Q11)

**Q6.** An AXI4 master issues a INCR burst of length 8 (AxLEN = 0x7) to a slave starting at address 0x1000. The data width is 32 bits (4 bytes). What is the address of the final beat in the burst?

- A) 0x100C
- B) 0x101C
- C) 0x1020
- D) 0x1007

---

**Q7.** An AXI4 slave returns a DECERR response on the RRESP or BRESP channel. What does this indicate?

- A) The slave detected a data parity error during the transfer
- B) The transaction address did not map to any valid subordinate (decode error)
- C) The slave was temporarily busy and the master must retry the transaction
- D) The slave completed the transaction but the data is corrupted

---

**Q8.** AXI4 supports outstanding transactions, meaning a master can issue multiple transactions before receiving responses. Which field in the AXI4 channel signals is used to match a response to its original transaction?

- A) AWADDR / ARADDR
- B) AWID / ARID (transaction ID)
- C) AWLEN / ARLEN (burst length)
- D) AWBURST / ARBURST (burst type)

---

**Q9.** In the AHB protocol, a master wants to perform a sequential burst. The master asserts HTRANS = SEQ on all beats after the first. What does HTRANS = NONSEQ on the first beat indicate?

- A) The master is idle and not performing any transfer
- B) The first beat of a new burst or a single transfer is starting
- C) The master is requesting an exclusive access
- D) The previous transfer was aborted and the bus is being re-arbitrated

---

**Q10.** AXI4 write transactions use separate write address (AW) and write data (W) channels. In AXI4, can the write data channel be advanced ahead of the write address channel?

- A) No, the write address must always be accepted by the slave before any write data is sent
- B) Yes, the master may issue write data before or in parallel with the write address; the slave must buffer data until the address arrives
- C) Yes, but only for burst transactions where the address is implied from the previous beat
- D) No, AXI4 requires strict ordering: address, then data, then response in sequential clock cycles

---

**Q11.** The CHI (Coherent Hub Interface) protocol introduces a "Home Node" (HN) concept. What is the role of the Home Node in a CHI transaction?

- A) It acts as the bus master initiating all cache line fetch requests
- B) It is the centrally-located coherency directory that tracks cache line states across all Request Nodes and manages point-of-coherency ordering
- C) It is the physical memory controller that services all DRAM read and write requests
- D) It is an ARM trademark name for the CPU cluster that owns the cache hierarchy

---

### Advanced (Q12 -- Q15)

**Q12.** An AXI4 master issues an exclusive read (ARLOCK = 1) followed by an exclusive write (AWLOCK = 1) to the same address. The exclusive write returns EXOKAY. What does this guarantee?

- A) The read-modify-write sequence completed atomically with no other bus master accessing the same address
- B) No other master wrote to the same address between the exclusive read and the exclusive write on this master
- C) The slave has hardware locked the address range and will reject all other masters until the exclusive write completes
- D) The transaction was completed without any bus errors and the data is valid

---

**Q13.** An AXI4-Stream interface carries fixed-width 32-bit words with TKEEP and TSTRB. On the final beat of a frame, TLAST = 1, TKEEP = 4'b0011, TSTRB = 4'b0011. What does this indicate about the final beat?

- A) All four bytes are valid data bytes that should be written to memory
- B) Only the two least-significant bytes (byte lanes 0 and 1) contain valid data; the upper two bytes are null bytes that should be discarded
- C) The frame is malformed; TKEEP and TSTRB must always be all-ones on the final beat
- D) The transfer should be retried because fewer than four bytes were received

---

**Q14.** An APB bridge connects a high-speed AXI4 master to a set of APB slaves. The AXI4 master performs a write transaction that completes in two cycles. The APB slave requires a three-cycle SETUP + ACCESS + WAIT sequence. What happens?

- A) The AXI4 transaction is split into multiple sub-transactions by the bridge
- B) The APB bridge holds off the AXI4 master by de-asserting WREADY until the APB transaction completes, absorbing the timing difference
- C) The APB WAIT state causes a bus error on the AXI4 side because AXI4 does not support stalling
- D) The APB bridge discards the WAIT state and completes the transaction in two cycles to match AXI4 timing

---

**Q15.** In a CHI network, a Request Node (RN-F) issues a ReadUnique request for a cache line. The Home Node finds that another RN-F currently holds the line in the Shared state. Which sequence of operations does the Home Node typically orchestrate?

- A) It sends a SnpUnique snoop to the sharer, the sharer returns the data and invalidates its copy, the HN sends the data to the requester marked Unique
- B) It forwards the data directly from DRAM to the requester without snooping other caches
- C) It sends a CompAck to the requester immediately and allows both nodes to hold Unique copies temporarily
- D) It blocks the requester until the sharer voluntarily evicts the line, then services the request



---

## Answer Key

| Q  | Answer |
|----|--------|
| 1  | C      |
| 2  | C      |
| 3  | B      |
| 4  | C      |
| 5  | B      |
| 6  | B      |
| 7  | B      |
| 8  | B      |
| 9  | B      |
| 10 | B      |
| 11 | B      |
| 12 | B      |
| 13 | B      |
| 14 | B      |
| 15 | A      |

---

## Detailed Explanations

**Q1 -- Answer: C**

AXI4 Full defines five independent channels: Write Address (AW), Write Data (W), Write Response (B), Read Address (AR), and Read Data (R). The separation of write address, write data, and write response into three channels (plus two read channels) enables the pipelining and out-of-order completions that give AXI4 its high performance. Option A is too coarse a grouping. Option B groups them incorrectly. Option D omits the write response channel (B channel).

---

**Q2 -- Answer: C**

The fundamental AXI handshake rule: a transfer (beat) occurs on the clock edge where both VALID and READY are simultaneously high. The sender drives VALID when it has valid data or can accept a transaction; the receiver drives READY when it can accept. Neither party may wait for the other before asserting its own signal (to avoid combinational loops), but the transfer itself only happens when both signals coincide. Option A (VALID alone) and option B (READY alone) are individually necessary but not sufficient. Option D is not a requirement -- READY may arrive before VALID and there is no minimum separation constraint.

---

**Q3 -- Answer: B**

AXI4-Lite is a simplified subset of AXI4 intended for register-level peripheral access. It does not support bursts (every transaction is a single beat, AxLEN = 0), exclusive accesses, or multiple outstanding transactions. AXI4 Full supports INCR, WRAP, and FIXED bursts up to 256 beats, exclusive accesses, and many outstanding transactions. Option A has the burst support backwards. Option C is wrong; both protocols support 32-bit and 64-bit data widths depending on the implementation. Option D is wrong; AXI4-Lite retains the write response (B) channel -- this is an important distinction from APB, which has no response channel.

---

**Q4 -- Answer: C**

TLAST marks the final beat of a packet (or frame) in an AXI4-Stream transfer. The receiver uses TLAST to detect packet boundaries and reassemble frames. TVALID indicates the transmitter has valid data on the current beat. TREADY indicates the receiver is ready to accept data. TKEEP indicates which byte lanes carry valid data bytes (versus padding bytes). None of the other signals carry the end-of-packet semantic.

---

**Q5 -- Answer: B**

APB is designed for simple, low-bandwidth peripheral registers such as GPIO, UART configuration, and timer controls. It is non-pipelined: each transaction takes at least two cycles (SETUP and ENABLE phases) and no new transfer can begin until the current one completes. This simplicity reduces implementation cost and power for peripherals that do not need high throughput. Option A describes AHB or AXI. Option C describes ACE or CHI. Option D describes a serial protocol such as SPI or I2C.

---

**Q6 -- Answer: B**

An INCR burst increments the address by the data width on each beat. With 32-bit (4-byte) data and AxLEN = 7 (8 beats), the addresses are 0x1000, 0x1004, 0x1008, 0x100C, 0x1010, 0x1014, 0x1018, 0x101C. The final beat is at 0x101C. Option A (0x100C) is only the 4th beat. Option C (0x1020) is one address past the final beat (the address that would start the next burst). Option D (0x1007) makes no sense for a word-aligned burst.

---

**Q7 -- Answer: B**

DECERR (decode error) on RRESP or BRESP indicates that no subordinate claimed the transaction address -- the address fell outside all mapped regions in the interconnect or a default slave returned the error. This differs from SLVERR (slave error), which means a valid subordinate accepted the address but encountered an error processing the request (such as a permission violation or unsupported operation). Option A describes a data integrity error, which AXI4 does not natively signal in RRESP/BRESP (ECC errors are usually handled by a separate sideband). Option C describes a RETRY response, which AXI4 does not have. Option D incorrectly conflates DECERR with a data corruption indication.

---

**Q8 -- Answer: B**

AXI4 transaction IDs (AWID, WID, BID, ARID, RID) allow a master to tag transactions and match responses to their originating requests. A slave or interconnect that processes transactions out of order uses the ID to return each response with the same ID as the original request. The master's response logic uses the ID to route the response to the correct waiting thread or register. Address fields identify the target location, not the transaction identity. Burst length and burst type are transaction parameters, not transaction identifiers.

---

**Q9 -- Answer: B**

AHB HTRANS encoding: IDLE (2'b00) means no transfer; BUSY (2'b01) is used within a burst to insert idle cycles; NONSEQ (2'b10) indicates the start of a new burst or a single transfer; SEQ (2'b11) indicates a continuation beat of a burst whose address is derived from the previous beat plus the beat size. The first beat of every new burst or single transfer uses NONSEQ to signal to the slave and interconnect that a new transaction address is present on HADDR. Option A describes the IDLE state. Option C does not exist in AHB as a HTRANS encoding. Option D does not map to any AHB signal; re-arbitration is signalled through HBUSREQ/HGRANT, not HTRANS.

---

**Q10 -- Answer: B**

AXI4 explicitly allows write data to be interleaved or issued ahead of the corresponding write address. A compliant slave must buffer incoming write data until the associated write address arrives on the AW channel. This decoupling enables high-performance masters to issue data before address translation completes. It is a common interview trap: many engineers assume the address must precede data. Option A incorrectly enforces a strict ordering that the specification does not require. Option C describes a non-existent AXI4 feature. Option D describes a non-pipelined protocol model inconsistent with AXI4.

---

**Q11 -- Answer: B**

In CHI, the Home Node (HN) is the coherency directory controller and point of serialisation (PoS) for a given address range. It tracks which Request Nodes (RN-F, fully coherent) currently hold cached copies of each line and in what state. When a request arrives, the HN determines what snoops are needed, orchestrates them, collects responses, and completes the transaction. The HN-F variant also connects to system-level cache (SLC). Option A reverses the roles -- RN-F nodes initiate requests, the HN responds. Option C describes the Slave Node (SN), which is the memory controller interface. Option D is incorrect; the term is an ARM-defined architectural role, not a name for the CPU cluster.

---

**Q12 -- Answer: B**

AXI4 exclusive accesses implement a load-linked/store-conditional (LL/SC) mechanism. The exclusive monitor records the address when the exclusive read is performed. If any other agent writes to the monitored address before the exclusive write, the monitor clears. An EXOKAY response on the exclusive write means the monitor was still set -- i.e., no other write to that address occurred between the exclusive read and this exclusive write from this master's perspective. Option A overstates the guarantee: AXI4 exclusive accesses are not a hardware lock and do not prevent other masters from attempting accesses. Other writes are possible; the exclusive write simply fails (returns OKAY rather than EXOKAY) if the monitor was cleared. Option C describes a hardware bus lock, which AXI4 does not implement. Option D describes an ordinary OKAY response, not the exclusive semantics.

---

**Q13 -- Answer: B**

In AXI4-Stream, TKEEP[n] = 1 indicates that byte lane n contains a valid data byte; TKEEP[n] = 0 indicates a null byte (padding) that must be discarded by the receiver. TSTRB further distinguishes position bytes (TSTRB = 1) from null bytes (TSTRB = 0). With TKEEP = TSTRB = 4'b0011, byte lanes 0 and 1 are valid data; byte lanes 2 and 3 are null bytes. Option A is wrong because only two of the four byte lanes are marked valid. Option C is incorrect; TKEEP less than all-ones on the final beat is explicitly supported to handle payloads whose length is not a multiple of the bus width. Option D is wrong; the protocol specifies how to handle partial final beats, not that they are errors.

---

**Q14 -- Answer: B**

An AXI4-to-APB bridge acts as an AXI4 slave and an APB master. When the AXI4 master writes, the bridge accepts the AXI4 transaction, holds off the AXI4 side by de-asserting WREADY (or by holding BVALID until ready), and runs the APB transaction including any WAIT states. Only when the APB transaction completes with PREADY does the bridge assert BVALID and return the write response to the AXI4 master. This is the standard bridge behaviour. Option A is wrong; AXI4 does not split single transactions. Option C is wrong; AXI4 is fully flow-controlled and the stall is handled by WREADY/BVALID, not by an error. Option D is wrong; discarding PREADY extensions would produce incorrect behaviour on the peripheral.

---

**Q15 -- Answer: A**

ReadUnique requires the requester to obtain an exclusive (Unique) copy with write permission. If any other node holds the line in Shared state, the Home Node must invalidate those copies. The HN sends a SnpUnique snoop to the sharer. The sharer invalidates its copy and returns the data (if it is dirty) or just an acknowledgement (if clean). The HN then provides the data to the requester and grants it a Unique state. Option B is wrong: CHI requires snooping existing sharers before granting Unique -- forwarding from DRAM without snooping would allow two nodes to have copies simultaneously. Option C is wrong: issuing CompAck before snooping would leave the sharer with a valid copy while also granting Unique to the requester, violating coherency. Option D is wrong: CHI does not rely on voluntary eviction; it actively snoops to enforce the coherency state machine.
