# Security and TrustZone

## Overview

Security in SoC architecture spans hardware root of trust, memory partitioning, secure boot chains, cryptographic acceleration, and the firmware abstractions that tie these mechanisms together. Arm TrustZone is the foundational hardware security mechanism on virtually every modern mobile, automotive, and embedded processor. Understanding how the hardware enforces security boundaries — and why those boundaries can be bypassed when misconfigured — is essential knowledge for any SoC architect or integration engineer.

This document covers TrustZone architecture, the secure/non-secure world partitioning, TEE fundamentals, secure boot chain design, and common attack surfaces. All topics reflect real-world implementations in production SoCs.

---

## Tier 1: Fundamentals

### Q1. What problem does Arm TrustZone solve, and what is its core architectural mechanism?

**Answer:**

The problem TrustZone addresses: a general-purpose OS (Linux, Android) runs untrusted third-party applications and is itself a large, complex codebase with a significant attack surface. Security-sensitive operations — DRM key handling, biometric data processing, mobile payments, secure storage — cannot be safely performed within this environment because a compromised OS can read or modify any memory it can address.

TrustZone solves this by creating a hardware-enforced separation between two execution environments on the same physical processor:

- **Secure World (SW):** A small, trusted execution environment (TEE) running a minimal, auditable OS (e.g., OP-TEE, Trustonic Kinibi). Only Secure World code can access secure memory regions, secure peripherals, and cryptographic key stores.
- **Normal World (NW):** The standard rich OS (Linux/Android). Large, complex, potentially compromised. Cannot access Secure World resources regardless of privilege level.

**Core mechanism — NS bit:**

TrustZone adds a single physical signal called the **NS (Non-Secure) bit** to every AXI/AHB bus transaction. This bit propagates through the entire interconnect:

- When the processor is executing in Secure World: NS = 0
- When executing in Normal World: NS = 1

Every memory controller, peripheral, and bus interconnect component checks the NS bit against its configuration. A transaction with NS = 1 attempting to access a Secure World resource is rejected by the hardware — the Normal World cannot escalate this regardless of software privilege (kernel, root, hypervisor do not matter).

The NS bit is analogous to the hardware ring protection of x86 (user/kernel privilege) but it is *orthogonal* to privilege level — a Secure World user-space thread (EL0S) has more hardware authority over memory than a Normal World kernel (EL1N).

---

### Q2. Describe the Arm exception level hierarchy and how TrustZone maps onto it.

**Answer:**

Armv8-A defines four exception levels (EL0–EL3) that exist in both Secure and Normal worlds, except EL3 which exists only in the Secure World:

```
Exception Level    Normal World (NS=1)     Secure World (NS=0)
─────────────────  ──────────────────────  ──────────────────────────
EL3 (Monitor)      (does not exist)        Secure Monitor (ATF BL31)
                                            Controls world switching
EL2 (Hypervisor)   Hypervisor (KVM)        Secure EL2 (optional, v8.4+)
EL1 (OS Kernel)    Linux / Android kernel  Secure OS (OP-TEE, Trustonic)
EL0 (User)         User apps (Android)     Trusted Applications (TAs)
```

**World switching mechanism:**

The only way to switch between Normal World and Secure World is via the Secure Monitor at EL3. The mechanism:

1. Normal World code (any EL) executes `SMC` (Secure Monitor Call) instruction.
2. The processor raises an exception to EL3.
3. The Secure Monitor (ATF) saves the Normal World CPU state (registers, PC, SPSR).
4. ATF determines the request type (PSCI call, TEE request, etc.).
5. If the request is for the TEE, ATF restores the Secure World state and switches NS bit to 0.
6. Secure OS handles the request and calls `SMC` again (or ERET) to return.
7. ATF restores Normal World state, NS = 1, returns to Normal World.

**Why EL3 controls switching:**

The NS bit in the SCR_EL3 (Secure Configuration Register) is only writable from EL3. No Normal World software, regardless of privilege (EL0–EL2), can clear the NS bit to enter Secure World. This hardware enforcement is what makes the isolation meaningful.

---

### Q3. What is the TZASC and how does it enforce memory partitioning?

**Answer:**

The **TrustZone Address Space Controller (TZASC)** is an AXI bus component that partitions physical DRAM into Secure and Non-Secure regions. It sits in the data path between the memory controller and the main interconnect (NIC/CCI/CMN), filtering every read and write transaction based on its NS bit.

**Operation:**

The TZASC is programmed by Secure World firmware (typically during secure boot) to define memory regions:

```
TZASC Region Configuration (example):
Region 0: 0x00000000 – 0x3FFFFFFF  → Non-Secure (1 GB, Normal World DRAM)
Region 1: 0x40000000 – 0x41FFFFFF  → Secure (32 MB, TEE OS + TA heap)
Region 2: 0x42000000 – 0x421FFFFF  → Secure (2 MB, secure framebuffer)
Region 3: 0x42200000 – 0xFFFFFFFF  → Non-Secure (remaining DRAM)
```

For each incoming transaction:
- NS = 0 (Secure World): access permitted to all regions.
- NS = 1 (Normal World): access to Secure regions is blocked. The TZASC returns a bus error (SLVERR or DECERR on AXI) to the initiator.

**TZASC programming timing:**

Critically, the TZASC must be programmed and locked before Normal World is allowed to execute. If the bootloader starts the Normal World OS before setting TZASC regions, the OS could access secure DRAM before it is protected. Secure boot chain implementation must:

1. Configure TZASC regions in BL2/BL31 (ATF stages).
2. Lock the TZASC configuration (write-protect the region registers from Non-Secure access).
3. Only then release the Normal World.

**TZPC (TrustZone Protection Controller):**

Separate from TZASC, the TZPC marks individual peripherals as Secure or Non-Secure. A UART assigned as Secure can only be accessed by Secure World. Commonly, the root of trust peripherals (OTP fuses, cryptographic accelerator, secure RTC) are marked Secure via TZPC.

---

### Q4. What is a Trusted Execution Environment (TEE)? What are its core security properties?

**Answer:**

A TEE is the Secure World software environment that provides isolated execution for security-sensitive operations. The four core security properties, as defined by GlobalPlatform:

**1. Isolated Execution:**
TEE code and data cannot be read or modified by Normal World software. This is enforced by TrustZone hardware (TZASC for memory, NS bit for bus transactions). A compromised Android kernel cannot extract TEE secrets.

**2. Trusted Storage:**
TEE provides persistent storage for secrets (private keys, DRM licenses) that is encrypted with a key derived from the hardware root of trust (e.g., a key fused into OTP). Even if an attacker reads the storage medium physically, the data is encrypted with a device-unique key that never leaves the TEE.

**3. Secure Communication:**
Standardised API (GlobalPlatform TEE Internal Core API) defines how Trusted Applications (TAs) communicate with the Normal World. Communication passes through a controlled channel: the Normal World calls `TEEC_InvokeCommand()`, which triggers an SMC to EL3, which routes to the TEE OS, which calls the appropriate TA.

**4. Trusted Time:**
A monotonic counter or secure RTC accessible only from Secure World prevents time-rollback attacks. Anti-replay for OTA firmware updates relies on the TEE's trusted time or a rollback counter stored in OTP.

**TEE software stack (OP-TEE example):**

```
Normal World (NS=1)          Secure World (NS=0)
─────────────────────        ─────────────────────
Android application          Trusted Application (TA)
    │                                │
libteec (user library)       TEE Internal Core API
    │                                │
TEE driver (kernel)          OP-TEE OS (Secure EL1)
    │                                │
    └─────── SMC ──────────► EL3 Secure Monitor (ATF)
```

**Trusted Applications (TAs):**

TAs are small, sandboxed programs loaded into TEE memory. Each TA has a UUID and runs in Secure EL0. Examples:
- DRM key processing TA (Widevine, PlayReady)
- Fingerprint matching TA
- FIDO2 authenticator TA
- Secure payment TA (SE simulation)

---

### Q5. What is the boot ROM's role in hardware security? What makes it a root of trust?

**Answer:**

The **Boot ROM** is a read-only memory embedded in the SoC that executes immediately after reset, before any software loaded from external storage. It forms the root of trust because:

1. **Immutable:** ROM contents are fixed at chip manufacture. An attacker cannot modify the boot ROM — it has no write interface. All subsequent security guarantees depend on the boot ROM being correct.

2. **First executor:** Because it runs before anything else, there is no prior code that could have corrupted the system state. The processor starts in a known-clean state.

3. **Chain anchor:** The boot ROM cryptographically verifies the first-stage bootloader (BL1/BL2 in ATF terminology). If verification fails, boot halts. This extends the trust boundary to the next stage.

**Boot ROM responsibilities:**

1. Minimal hardware initialisation (clock startup, power-on sequencing).
2. Read the next-stage bootloader from flash/eMMC.
3. Retrieve the OEM public key hash from OTP fuses (the hardware root of trust public key).
4. Verify the next-stage bootloader signature using the OEM public key.
5. If verification passes, transfer control to the bootloader.
6. If verification fails, enter a recovery mode or halt (device-specific policy).

**Why OTP fuses?**

The public key (or its hash) used to verify the bootloader must be stored in a medium that:
- Cannot be modified after provisioning (prevents an attacker replacing the key with their own)
- Is on-chip (cannot be intercepted during read)
- Is unique per device (allows per-device revocation in some implementations)

One-Time Programmable (OTP) fuses satisfy all three. The OEM programs fuses during manufacturing. After programming, fuses are locked (additional fuses blown to make the lock register read-only).

---

## Tier 2: Intermediate

### Q6. Describe the full secure boot chain from power-on to OS load. Identify the trust anchor at each stage.

**Answer:**

The secure boot chain is a sequence of cryptographic verifications where each stage verifies the next before executing it. The chain ensures that only software authorised by the OEM (or platform owner) can run on the device.

**Arm Trusted Firmware (ATF) boot stages:**

```
Stage       Location     Verified by         Trust anchor
──────────  ───────────  ──────────────────  ─────────────────────────────
BL1         Boot ROM     Hardcoded in ROM     Silicon vendor (immutable ROM)
BL2         Flash        BL1 using OEM key    OEM public key hash in OTP
BL31        Flash        BL2 using OEM key    Same OEM key chain
BL32 (TEE)  Flash        BL2 using TEE key    TEE vendor / OEM key
BL33 (UEFI/uboot) Flash  BL2 using OEM key   Same OEM key chain
OS (kernel) Flash/eMMC   BL33 using OEM key  Key embedded in UEFI db
```

**Cryptographic mechanism at each stage:**

Each bootloader image is packaged with a Firmware Image Package (FIP) containing:
- The binary image
- A certificate chain (X.509 or custom)
- An RSA/ECDSA signature over the image hash

Verification:
```
1. Compute SHA-256 of the received image → H_computed
2. Decrypt the signature using the trusted public key → H_expected
3. Compare H_computed == H_expected
4. Verify the certificate chain back to the root key in OTP
5. Check version number against anti-rollback counter in OTP
```

**Anti-rollback mechanism:**

OTP contains a monotonic counter (implemented as a sequence of one-time-blowable fuse bits). Each image has a minimum version number. If the image version < OTP counter, boot is rejected. After a successful boot, the OTP counter is incremented to prevent downgrade to a vulnerable older version.

```
OTP fuse field (8 bits, each fuse blown = 1):
0000 0000 → counter = 0
0000 0001 → counter = 1 (one fuse blown)
0000 0011 → counter = 2
0000 1111 → counter = 4
1111 1111 → counter = 8 (all blown, maximum version)
```

**Key hierarchy:**

```
Device Root Key (in Hardware Security Module at manufacturing)
        │
        └─► OEM Root CA (stored in OTP fuse hash)
                │
                ├─► BL2 Signing Key
                ├─► BL31 Signing Key
                ├─► BL32 Signing Key (TEE OS)
                └─► BL33 Signing Key (UEFI)
```

Each signing key can be revoked independently by blowing additional OTP fuses without revoking the root.

---

### Q7. What are the key attack surfaces against TrustZone, and what hardware mitigations exist?

**Answer:**

**Attack surface 1 — Physical memory attacks (DRAM):**

DRAM is external to the SoC. An attacker with physical access can:
- **Cold boot attack:** Freeze DRAM chips, transfer to attacker hardware, read contents. TEE data loaded in Secure DRAM is exposed.
- **DMA attack:** A malicious peripheral (e.g., a Thunderbolt device) may be able to issue DMA reads to Secure DRAM if the IOMMU/TZASC is misconfigured.

**Mitigation:**
- DRAM encryption (DME/inline encryption): AES-128 or AES-256 encryption at the memory controller. Secure DRAM is encrypted with a key stored in on-chip SRAM, never leaving the SoC. Even if DRAM is probed physically, data is encrypted.
- TZASC correctly configured and locked before DMA-capable peripherals are activated.
- SMMU (System MMU) for all DMA-capable peripherals: assigns a per-device IOMMU context that restricts DMA to Non-Secure Normal World memory only.

**Attack surface 2 — Shared memory communication channel:**

The Normal World and Secure World must share a communication buffer (Normal World DRAM that both can read). A Time-of-Check to Time-of-Use (TOCTOU) attack:
1. Normal World prepares a valid command buffer.
2. TEE validates the buffer contents.
3. Normal World (another thread) modifies the buffer after validation but before TEE uses it.

**Mitigation:**
- TEE copies parameters from shared buffer into Secure DRAM before validation.
- Shared memory is never writeable by Normal World after the TEE begins processing.
- OP-TEE uses parameter copying by default.

**Attack surface 3 — Speculative execution (Spectre variant 1 inside TEE):**

Speculative reads in Secure World code can be used to exfiltrate TEE secrets via cache timing side channels, even from Normal World code in some configurations.

**Mitigation:**
- EL3 (Secure Monitor) flushes TLBs, caches, and branch predictors during world switch.
- Arm Spectre v2 mitigation (SSBS bit, CSV2 architectural isolation).
- TEE OS applies index masking before speculative array accesses.

**Attack surface 4 — Rollback attack:**

An attacker downgrades firmware to a version with known vulnerabilities.

**Mitigation:** Anti-rollback OTP counters as described in Q6.

**Attack surface 5 — Side-channel attacks on cryptographic operations:**

Power analysis (SPA/DPA) or electromagnetic analysis can extract AES/RSA keys from a TEE's cryptographic implementation if not protected.

**Mitigation:**
- Use hardware cryptographic accelerators with built-in side-channel countermeasures (random delay insertion, power normalisation).
- Constant-time software implementations of cryptographic algorithms.
- Masking: represent key bits as (key XOR random_mask), ensuring power consumption is independent of the key value.

---

### Q8. How does the SMMU (System MMU) interact with TrustZone to provide DMA isolation?

**Answer:**

The System MMU (Arm SMMU-v3 specification) provides I/O virtualisation and DMA protection for bus masters (DMA engines, GPU, IOMMU clients) that are not processors. Without an SMMU, a DMA-capable device with a bus master interface can read or write any physical address — including Secure World DRAM.

**SMMU architecture:**

```
DMA Device ──► [SMMU] ──► Interconnect ──► Memory Controller
               │
               │ Stream ID (SID): identifies the DMA device
               │
               ▼
         Stage 1 Page Table (device virtual → IPA)
         Stage 2 Page Table (IPA → PA, used with hypervisor)
         Stream Table (maps SID to page table base)
```

**TrustZone integration:**

The SMMU has its own NS bit in its configuration registers. Two critical properties:

1. **SMMU is a Secure peripheral:** Its stream tables and context banks are programmed by Secure World (ATF during boot). Normal World cannot reconfigure the SMMU to expand a device's DMA range into Secure DRAM.

2. **NS output bit:** The SMMU sets the NS bit on outgoing transactions based on the stream table entry. A Normal World DMA device always produces NS = 1 transactions, which are rejected by the TZASC for Secure memory regions.

**Hypervisor use case (Stage 2):**

With a hypervisor (KVM), Stage 2 translation maps guest physical addresses (IPA) to actual physical addresses (PA). This prevents a VM from configuring its DMA device to access another VM's DRAM. The SMMU enforces this without the Secure World being involved.

**Bypass risk — misconfigured bypass:**

The SMMU has a bypass mode per stream. If a device's stream ID is not found in the stream table, the SMMU can be configured to either:
- Fault (safe: block the transaction)
- Bypass (unsafe: allow the transaction to proceed with the device's NS bit)

A device in bypass mode with NS = 0 (if the device has Secure World access) can access Secure DRAM. This is a critical misconfiguration. Production silicon must set the SMMU default to fault mode and explicitly enumerate all DMA-capable devices.

---

### Q9. What is measured boot and how does it differ from secure boot?

**Answer:**

**Secure boot** (verified boot) uses cryptographic signatures to ensure that only authorised software runs. Each stage either passes verification (and executes) or fails (and halts). It is binary: the device either boots authorised software or does not boot. It does not record what ran.

**Measured boot** records a cryptographic fingerprint (measurement) of every software component loaded during boot into a tamper-resistant log. It does not itself prevent unauthorised code from running — it provides an auditable record of what did run, enabling remote attestation.

**TPM (Trusted Platform Module) and PCRs:**

Measured boot is typically implemented with a TPM. The TPM contains Platform Configuration Registers (PCRs), which are extend-only registers:

$$PCR_{new} = SHA256(PCR_{old} \| measurement)$$

The chain structure means you cannot forge a PCR value without knowing every preceding measurement in order.

**Boot sequence with measurement:**

```
Stage      Action                                       PCR extended
─────────  ───────────────────────────────────────────  ──────────────
UEFI/BL1   Measure BL2 binary → H(BL2)                PCR[0]
BL2        Measure BL31, BL32, BL33 → H(each)          PCR[1], PCR[2]
UEFI       Measure kernel image → H(kernel)             PCR[4]
kernel     Measure initrd, command line                 PCR[8], PCR[9]
```

**Remote attestation:**

A remote server sends a challenge nonce. The TPM signs `PCR_values || nonce` with its device-private key (the Attestation Key, AK). The server:
1. Verifies the TPM signature using the AK certificate (provisioned at manufacture).
2. Checks the PCR values against the expected golden values for this firmware version.
3. If PCR values match, the server knows the device is running known-good firmware.
4. Server issues a session key for encrypted communication.

**Comparison:**

| Property | Secure Boot | Measured Boot |
|---|---|---|
| Prevents unauthorised code | Yes (halts on failure) | No (records but does not block) |
| Detects code modification | Yes (signature failure) | Yes (PCR mismatch in attestation) |
| Remote auditability | No | Yes (attestation report) |
| Granularity | Binary (pass/fail) | Fine-grained (per-component hash) |
| Use case | Consumer devices | Enterprise, cloud, automotive safety |

Most production devices implement both: secure boot as the enforcement mechanism, measured boot as the audit trail.

---

## Tier 3: Advanced

### Q10. Design the security architecture for a mobile payment SoC. Identify all hardware blocks required, define trust boundaries, and describe the complete transaction flow for a contactless payment.

**Answer:**

**Required hardware blocks:**

```
┌──────────────────────────────────────────────────────────────────┐
│                        Mobile Payment SoC                        │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────┐│
│  │ Application   │  │    TEE       │  │   Hardware Security     ││
│  │ Processor     │  │  (OP-TEE)   │  │   Module (HSM)          ││
│  │ (Normal World)│  │ (Sec World) │  │                         ││
│  └──────┬───────┘  └──────┬───────┘  │  ┌─────────────────┐   ││
│         │                 │          │  │  Secure Key Store│   ││
│  ┌──────▼───────────────┐ │          │  │  (device keys,   │   ││
│  │     Interconnect     │◄┘          │  │   payment keys)  │   ││
│  │  (CCI/CMN, TZASC)   │            │  └────────┬────────┘   ││
│  └──────────────────────┘            │           │             ││
│                                      │  ┌────────▼────────┐   ││
│  ┌───────────┐  ┌──────────────────┐ │  │  Crypto Engine  │   ││
│  │   NFC     │  │  TZASC + SMMU   │ │  │  (AES, ECC,     │   ││
│  │Controller │  │  (memory guard)  │ │  │   TRNG, SHA)    │   ││
│  └───────────┘  └──────────────────┘ │  └─────────────────┘   ││
│                                      │                         ││
│  ┌───────────┐  ┌──────────────────┐ │  ┌─────────────────┐   ││
│  │   DRAM    │  │  OTP Fuses       │ │  │  Secure Boot ROM│   ││
│  │(encrypted)│  │  (key hash,      │ │  │  (Root of Trust)│   ││
│  └───────────┘  │   anti-rollback) │ └──┴─────────────────┴───┘│
│                 └──────────────────┘                            │
└──────────────────────────────────────────────────────────────────┘
```

**Trust boundaries:**

1. **Boot ROM / OTP boundary:** Immutable root of trust. Only silicon vendor can modify (physically cannot be modified post-manufacture).
2. **Secure World / Normal World boundary:** Enforced by NS bit, TZASC, TZPC.
3. **TEE / HSM boundary:** The HSM is a separate hardened block. The TEE communicates with the HSM via a Secure-only bus; the Normal World cannot access the HSM bus directly even from Secure World userspace.
4. **SoC / NFC controller boundary:** NFC transactions are routed through the Secure Element (embedded HSM) directly, bypassing the application processor entirely for the cryptographic operations.

**Complete contactless payment flow (EMVCo NFC):**

```
Step 1 — Terminal initiates: NFC field energises, ISO 14443 RF communication begins.

Step 2 — NFC routing to Secure Element:
  NFC controller detects EMV payment AID (Application Identifier)
  HCI/SWP (Single Wire Protocol) routes the command directly to the
  embedded Secure Element, NOT to the application processor.
  The Normal World OS is not involved.

Step 3 — Card emulation in Secure Element:
  SE runs the payment application (e.g., Visa payWave, Mastercard PayPass)
  SE retrieves the card credentials (Primary Account Number, expiry date)
  from its internal secure storage (encrypted with SE root key).

Step 4 — Cryptogram generation:
  SE generates a transaction-specific cryptogram (AC):
    AC = CMAC_AES(ICC_session_key, ATC || Amount || Terminal_ID || Random)
  The ICC_session_key is derived per-transaction from the card master key,
  which never leaves the SE.

Step 5 — Response to terminal:
  SE sends the GENERATE AC response (track data + cryptogram) to the NFC
  controller, which transmits it over the RF channel to the terminal.
  The Normal World OS still has not been involved.

Step 6 — Backend verification:
  Payment terminal sends the cryptogram to the payment network.
  The network validates the cryptogram using its copy of the issuer master key.
  If valid, authorisation is approved.

Step 7 — Notification to Android application:
  NFC controller notifies the Normal World OS of transaction completion.
  HCE (Host Card Emulation) mode, if used instead of dedicated SE, routes
  the APDU commands to a TEE-based payment TA rather than the SE.
```

**Why the SE is separate from the TEE:**

The SE provides Common Criteria EAL5+ or EAL6+ evaluated security — a level of assurance that TrustZone alone does not achieve. Payment networks (Visa, Mastercard) require EMVCo SE Security Guidelines compliance, which mandates:
- Physical tamper evidence
- Side-channel resistance for cryptographic operations
- Secure key injection at manufacture

The TEE handles user authentication (PIN entry on-device, biometric) and passes an "allow payment" token to the SE, but the card credentials and cryptography live in the SE.

---

### Q11. A vulnerability report states that an attacker with Normal World root access can escalate to Secure World by exploiting a shared memory TOCTOU in a TEE Trusted Application. Analyse the vulnerability, classify its severity, and propose both short-term and long-term mitigations.

**Answer:**

**Vulnerability classification:**

A TOCTOU (Time-of-Check to Time-of-Use) vulnerability in TEE shared memory allows a Normal World attacker to modify command parameters after the TEE has validated them but before it uses them. This is a **Critical** severity vulnerability (CVSSv3 base score typically 8.5–9.8) because:

- An attacker with Normal World root can already control all Normal World resources.
- TOCTOU allows them to pass a validated "safe" command to the TEE, then swap in a malicious payload.
- If the TEE TA is a privileged operation (e.g., cryptographic key extraction, secure storage write), the attacker may be able to exfiltrate device keys or write malicious data to secure storage.
- In the worst case, a memory corruption bug in the TA triggered via TOCTOU allows arbitrary code execution in Secure World — full TEE compromise.

**Mechanism of exploit:**

```
Normal World Thread 1 (attacker):         TEE Trusted Application:
─────────────────────────────────────     ─────────────────────────────
1. Prepare valid buffer:                  
   shared_buf = {op: READ_KEY, id: 1}     
                                          
2. Call TEEC_InvokeCommand()              3. Receive command
   → SMC → EL3 → TEE OS → TA             4. Validate buffer:
                                             if (buf.id == 1 && buf.op == READ_KEY)
Normal World Thread 2 (attacker):         
─────────────────────────────────────        PASS
5. Modify buffer in shared memory:        
   shared_buf = {op: WRITE_KEY,           6. [GAP: buf not yet copied]
                 id: ROOT_KEY_SLOT}       
                                          7. Execute using current buf:
                                             execute(buf)  ← buf is now malicious
                                             → exports root key!
```

**Short-term mitigations:**

1. **Immediate parameter copy (defence at the TA level):**

```c
// VULNERABLE: using shared buffer directly after validation
TEE_Result ta_invoke_command(uint32_t cmd, TEE_Param params[4]) {
    uint32_t key_id = params[0].value.a;  // read from shared memory
    if (!validate_key_id(key_id)) return TEE_ERROR_BAD_PARAMETERS;
    return export_key(key_id);  // TOCTOU: key_id may have changed
}

// FIXED: copy parameters to Secure World stack immediately
TEE_Result ta_invoke_command(uint32_t cmd, TEE_Param params[4]) {
    uint32_t key_id = params[0].value.a;  // single atomic read
    uint32_t local_key_id = key_id;       // copy to Secure World stack
    if (!validate_key_id(local_key_id)) return TEE_ERROR_BAD_PARAMETERS;
    return export_key(local_key_id);  // uses local copy, immune to TOCTOU
}
```

All OP-TEE TAs should use `TEE_Param` values from the framework (which copies them into TEE heap) rather than reading directly from shared memory. The OP-TEE framework provides this by default for value parameters; memref parameters require explicit copying.

2. **Memory region marking — read-only mapping:**

After the Normal World writes the command buffer and invokes the TA, the shared memory region can be remapped as read-only from the Normal World's page tables by the TEE OS during the SMC processing. This prevents Thread 2 from modifying the buffer.

**Long-term mitigations:**

3. **Formal verification of TEE TA interface:**

Apply formal methods (Coq, Isabelle/HOL, or seL4-style verification) to the TA's parameter handling code. Prove that no execution path reads from shared memory more than once after validation. Tools like VeriFast (for C) can enforce memory model rules statically.

4. **Architectural isolation — zero-copy parameter passing:**

Redesign the TEE ABI to eliminate shared memory for parameters entirely. Instead, pass parameters in CPU registers (for small values) or in Secure DRAM buffers that the Normal World copies to, with the TEE OS transferring ownership atomically:

```
Normal World:
  1. Write parameters to NW buffer (normal_buf)
  2. Invoke SMC with (normal_buf_addr, length)

TEE OS (EL1S, during SMC handling):
  3. Map normal_buf as read-only in secure address space
  4. Copy normal_buf → secure_buf (in Secure DRAM)
  5. Unmap normal_buf
  6. Invoke TA with secure_buf only
  
TA:
  7. Reads only from secure_buf — Normal World has no write access
```

5. **Static analysis tooling in CI pipeline:**

Deploy tools that flag shared-memory multi-read patterns:
- Coccinelle (semantic patch tool for C): write a semantic patch that identifies `params[N]` references appearing more than once after a validation check.
- OP-TEE fuzzer (LibFuzzer-based): continuous fuzzing of TA command handlers with concurrent Normal World mutation.

**Severity escalation factor:**

The final CVSSv3 score depends on whether the TOCTOU leads to information disclosure (key leakage) or code execution. If a vulnerable TA processes a memref (pointer + size) rather than a scalar value, swapping the pointer after validation to point into Secure DRAM can cause the TA to write attacker-controlled data to TEE memory — a full arbitrary write primitive. This escalates from "key leakage" to "TEE code execution," which is the highest possible severity in a TrustZone-based system.

---

## Quick Reference: Key Terms

| Term | Definition |
|---|---|
| TrustZone | Arm hardware security extension adding NS bit to partition Secure/Normal worlds |
| NS bit | Non-Secure bit on AXI transactions; hardware-enforced access control signal |
| EL3 | Exception Level 3; Secure Monitor only; controls world switching via SCR_EL3.NS |
| SMC | Secure Monitor Call; only way for software to request a world switch |
| TEE | Trusted Execution Environment; the Secure World software stack |
| TA | Trusted Application; sandboxed Secure EL0 program in the TEE |
| TZASC | TrustZone Address Space Controller; partitions DRAM into Secure/Non-Secure |
| TZPC | TrustZone Protection Controller; marks individual peripherals as Secure/Non-Secure |
| SMMU | System MMU; provides DMA isolation for bus masters; prevents peripheral attacks on Secure DRAM |
| Boot ROM | Immutable on-chip ROM; executes first; hardware root of trust anchor |
| OTP | One-Time Programmable fuse; stores OEM key hash and anti-rollback counters |
| Secure boot | Cryptographic verification of each boot stage before execution |
| Measured boot | Records SHA-256 fingerprints of boot stages into TPM PCRs for attestation |
| Anti-rollback | OTP monotonic counter preventing downgrade to vulnerable firmware versions |
| TOCTOU | Time-of-Check to Time-of-Use race condition in shared memory TEE communication |
| HSM | Hardware Security Module; dedicated tamper-resistant cryptographic processor |
| ATF | Arm Trusted Firmware; open-source reference implementation of EL3 Secure Monitor |
