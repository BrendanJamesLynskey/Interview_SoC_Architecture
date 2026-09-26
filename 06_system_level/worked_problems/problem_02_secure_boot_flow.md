# Problem 02: Secure Boot Flow with Chain of Trust

## Problem Statement

You are the security architect for a consumer IoT SoC (a smart home hub) based on an Arm Cortex-A53 processor. The device will ship with OEM firmware and must prevent customers (and attackers) from running unauthorised code. The threat model includes:

- A physically-present attacker with a flash programmer and logic analyser.
- A remote attacker exploiting a vulnerability in the application OS.
- An attacker attempting to downgrade firmware to a version with known vulnerabilities.
- Supply chain attacks: counterfeit devices flashed with attacker firmware at the distribution warehouse.

**Hardware available:**

- Arm Cortex-A53 with TrustZone
- 4 MB Boot ROM (embedded, read-only after mask ROM tape-out)
- 512-bit OTP fuse bank (blowable via JTAG during manufacturing)
- SPI NOR flash: 32 MB (external, writable in-field via OTA)
- LPDDR4: 1 GB (external)
- Hardware AES-128/256 + SHA-256 + RSA-2048 accelerator (in always-on domain)
- TRNG (True Random Number Generator)

**Deliverables:**

1. Define the complete chain of trust: list every stage from power-on to OS load, the binary stored at each stage, where it is stored, and who signs it.

2. Design the OTP fuse layout. What data goes into each fuse region, how many bits does each require, and how are they protected from modification?

3. Write pseudocode for the Boot ROM verification routine, handling signature verification and anti-rollback.

4. Identify three specific threat model scenarios and trace how the secure boot chain prevents each attack.

5. Discuss what happens when OTA (over-the-air) firmware update is received. How is the update verified and applied safely?

---

## Worked Solution

### Step 1: Chain of Trust Definition

The chain of trust is a directed acyclic graph where each node cryptographically vouches for the next. Trust is grounded in the immutable Boot ROM.

```
Power-on Reset
     │
     ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 0: Boot ROM (BL0)                                              │
│ Location: Embedded ROM (4 MB, immutable)                            │
│ Signed by: Nobody — it IS the root. Integrity guaranteed by mask.   │
│ Function: Hardware init, load BL1 from SPI flash offset 0x0000,     │
│           verify BL1 signature using OEM public key hash from OTP   │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ verification passes
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 1: First-Stage Bootloader (BL1 / SPL)                         │
│ Location: SPI NOR flash, offset 0x0000, size ≤ 256 KB              │
│ Signed by: OEM Root CA (private key held in HSM at OEM factory)     │
│ Function: DRAM init (LPDDR4 training), load BL2 from flash,         │
│           verify BL2 signature, check anti-rollback counter         │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage 2: Trusted Firmware BL2                                        │
│ Location: SPI NOR flash, offset 0x40000, size ≤ 512 KB             │
│ Signed by: OEM BL2 Signing Key (derived from OEM Root CA)           │
│ Function: Security init (TZASC, SMMU), load TEE OS + BL31 + BL33,  │
│           verify each, set up secure/non-secure memory regions      │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │ (parallel loads, serial verify)
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│ BL31: Secure    │  │ BL32: Secure OS      │  │ BL33: Normal World  │
│ Monitor (ATF)   │  │ (OP-TEE)            │  │ Bootloader (U-Boot) │
│ EL3, Secure     │  │ EL1S, Secure World  │  │ EL1N, Normal World  │
│ Signed: OEM key │  │ Signed: OEM TEE key │  │ Signed: OEM key     │
└────────┬────────┘  └──────────┬──────────┘  └──────────┬──────────┘
         │                      │                         │
         └──────────────────────┼─────────────────────────┘
                                │ BL2 hands off to BL31 ERET
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Stage Final: Linux Kernel + Verified Boot (dm-verity)               │
│ Location: eMMC (or SPI flash for small systems), signed partition   │
│ Signed by: OEM Kernel Signing Key                                   │
│ Function: Full OS; filesystem is dm-verity protected (root hash     │
│           stored in U-Boot FIT image header, verified at kernel load│
└─────────────────────────────────────────────────────────────────────┘
```

**Key relationships:**

| Stage | Verifies | Using key from |
|---|---|---|
| Boot ROM | BL1 | OEM public key hash in OTP |
| BL1 | BL2 | OEM public key (embedded in BL1, itself verified) |
| BL2 | BL31, BL32, BL33 | Per-component keys (certificate chain) |
| BL33 (U-Boot) | Linux kernel | OEM kernel signing key (FIT image header) |
| Linux (dm-verity) | Root filesystem | Root hash in verified kernel cmdline |

---

### Step 2: OTP Fuse Layout

**OTP bank: 512 bits (64 bytes) total**

```
Bit range    Field name              Size    Content                    Lock?
────────────────────────────────────────────────────────────────────────────────
[0:255]      OEM_ROOT_PUB_KEY_HASH  256 bits SHA-256(OEM_public_key)   Yes
             (SHA-256 of RSA-2048
              public key, 256 bits)
             
[256:263]    ANTI_ROLLBACK_BL1      8 bits   BL1 minimum version        Yes
             (monotonic counter,             (blown bit = +1 to version)
              8 fuses = version 0–8)
             
[264:271]    ANTI_ROLLBACK_BL2      8 bits   BL2 minimum version        Yes

[272:279]    ANTI_ROLLBACK_BL31     8 bits   BL31 minimum version       Yes

[280:287]    ANTI_ROLLBACK_BL32     8 bits   BL32 (TEE) minimum version Yes

[288:295]    ANTI_ROLLBACK_BL33     8 bits   BL33 minimum version       Yes

[296:303]    DEVICE_ID_HASH[7:0]    8 bits   Lower 8 bits of device     Yes
             (part of per-device            unique ID (for attestation)
              identity)
             
[304:311]    SECURITY_CONFIG        8 bits   Security feature flags:    Yes
                                             [0] JTAG_DISABLE
                                             [1] SECURE_BOOT_ENABLE
                                             [2] PRODUCTION_DEVICE
                                             [3] ROLLBACK_LOCK
                                             [4:7] Reserved
                                             
[312:319]    LOCK_BITS              8 bits   Write-protect other regions Yes (self)
                                             [0] Lock OEM_ROOT_KEY region
                                             [1] Lock ANTI_ROLLBACK region
                                             [2] Lock SECURITY_CONFIG
                                             [3:7] Reserved
                                             
[320:511]    RESERVED / SPARE       192 bits Future use / manufacturer  Varies
                                             test data
```

**OTP programming sequence (at factory):**

```
1. Generate OEM RSA-2048 key pair in HSM (private key never leaves HSM)
2. Compute SHA-256(OEM_public_key) → 256-bit hash value
3. Program OTP[0:255] with the hash via JTAG OTP programming interface
4. Program SECURITY_CONFIG[1] = 1 (SECURE_BOOT_ENABLE)
5. Program SECURITY_CONFIG[2] = 1 (PRODUCTION_DEVICE)
6. Program LOCK_BITS[0] = 1 (lock OEM key hash field)
7. Program LOCK_BITS[2] = 1 (lock SECURITY_CONFIG)
8. Disable JTAG: SECURITY_CONFIG[0] = 1
9. Program LOCK_BITS[1] = 1 (lock the lock bits — prevents clearing any locks)
```

**Why SHA-256 of the key, not the key itself:**

SHA-256 is 256 bits; RSA-2048 public key is 2048+ bits. The OTP bank is only 512 bits. Storing the hash and comparing it at runtime against the key in flash saves fuse bits. An attacker cannot find a different RSA key that hashes to the same SHA-256 value (collision resistance).

---

### Step 3: Boot ROM Verification Pseudocode

```c
/*
 * Boot ROM secure boot verification routine
 * Runs immediately after reset in Secure EL3
 * All code executes from ROM; no DRAM available yet
 */

#define OTP_KEY_HASH_ADDR    0xFFFF0000  // OTP controller MMIO
#define OTP_SECURITY_CFG     0xFFFF0020
#define OTP_ANTI_ROLLBACK    0xFFFF0030  // 6 bytes: BL1 through BL33
#define SPI_FLASH_BASE       0x10000000  // SPI NOR MMIO
#define BL1_FLASH_OFFSET     0x00000000
#define BL1_MAX_SIZE         (256 * 1024)
#define RSA_KEY_SIZE_BYTES   256         // RSA-2048 = 256 bytes
#define SHA256_SIZE_BYTES    32

typedef struct {
    uint32_t magic;          // 0x424C3031 = "BL01"
    uint32_t image_size;     // Size of BL1 binary in bytes
    uint8_t  version;        // Anti-rollback version
    uint8_t  reserved[3];
    uint8_t  signature[256]; // RSA-2048-PSS signature over SHA-256(magic || image_size ||
                             //   version || reserved || public_key || image) --
                             //   every header field except the signature itself
    uint8_t  public_key[294];// RSA-2048 public key (DER SubjectPublicKeyInfo)
    uint8_t  image[];        // Variable-length BL1 binary follows
} bl1_image_header_t;

boot_result_t boot_rom_verify_bl1(void) {
    uint8_t oem_key_hash[32];
    uint8_t computed_key_hash[32];
    uint8_t image_hash[32];
    bl1_image_header_t *header;
    uint8_t bl1_scratch[BL1_MAX_SIZE];

    /* Step 1: Read OEM root key hash from OTP */
    otp_read(OTP_KEY_HASH_ADDR, oem_key_hash, SHA256_SIZE_BYTES);

    /* Step 2: Check secure boot is enabled */
    uint32_t security_cfg = otp_read_word(OTP_SECURITY_CFG);
    if (!(security_cfg & SECURE_BOOT_ENABLE)) {
        /* Development device: skip verification, warn in debug output */
        uart_puts("WARNING: Secure boot disabled (development fuse)\n");
        spi_flash_read(SPI_FLASH_BASE + BL1_FLASH_OFFSET, bl1_scratch, BL1_MAX_SIZE);
        jump_to_image(bl1_scratch + sizeof(bl1_image_header_t));
        /* NOT REACHED */
    }

    /* Step 3: Read BL1 header from SPI flash (fits in ROM-internal buffer) */
    spi_flash_read(SPI_FLASH_BASE + BL1_FLASH_OFFSET,
                   (uint8_t *)&header, sizeof(bl1_image_header_t));

    /* Step 4: Validate magic number (quick sanity check before crypto) */
    if (header->magic != 0x424C3031) {
        uart_puts("ERROR: BL1 magic mismatch\n");
        return BOOT_ERROR_BAD_MAGIC;
    }

    /* Step 5: Bounds check image size */
    if (header->image_size == 0 || header->image_size > BL1_MAX_SIZE) {
        uart_puts("ERROR: BL1 image size out of range\n");
        return BOOT_ERROR_SIZE;
    }

    /* Step 6: Verify OEM public key against OTP hash
     * This proves the key in flash is the OEM's authorised key */
    hw_sha256(header->public_key, sizeof(header->public_key), computed_key_hash);

    if (memcmp_constant_time(computed_key_hash, oem_key_hash, SHA256_SIZE_BYTES) != 0) {
        uart_puts("ERROR: OEM key hash mismatch — unauthorised key in BL1 header\n");
        return BOOT_ERROR_KEY_MISMATCH;
    }
    /* OEM key is authentic. Now verify the image was signed with it. */

    /* Step 7: Read full BL1 image into scratch buffer */
    spi_flash_read(SPI_FLASH_BASE + BL1_FLASH_OFFSET + sizeof(bl1_image_header_t),
                   bl1_scratch, header->image_size);

    /* Step 8: Compute SHA-256 over the signed header fields AND the BL1 binary.
     * The header (including the anti-rollback version) must be covered by the
     * signature: if only the image were signed, an attacker could take an old,
     * validly signed image, raise the version in its header, and pass the
     * anti-rollback check in Step 10. */
    sha256_ctx_t ctx;
    hw_sha256_init(&ctx);
    hw_sha256_update(&ctx, (const uint8_t *)&header->magic,
                     offsetof(bl1_image_header_t, signature));   /* magic, image_size, version, reserved */
    hw_sha256_update(&ctx, header->public_key, sizeof(header->public_key));
    hw_sha256_update(&ctx, bl1_scratch, header->image_size);
    hw_sha256_final(&ctx, image_hash);   /* digest of header fields || image */

    /* Step 9: Verify RSA-2048-PSS signature
     * rsa_pss_verify(public_key, signature, message_hash) → 0=OK, else error */
    if (hw_rsa_pss_verify(header->public_key, header->signature, image_hash) != 0) {
        uart_puts("ERROR: BL1 signature verification failed\n");
        return BOOT_ERROR_BAD_SIGNATURE;
    }

    /* Step 10: Anti-rollback check
     * Read minimum version from OTP; reject if image version is lower */
    uint8_t min_version_bl1 = otp_read_byte(OTP_ANTI_ROLLBACK + 0);
    if (header->version < min_version_bl1) {
        uart_puts("ERROR: BL1 version below minimum (rollback attack)\n");
        return BOOT_ERROR_ROLLBACK;
    }

    /* Step 11: All checks passed. Jump to BL1 entry point.
     * Note: BL1 runs in Secure EL1, not EL3. Prepare EL3 → EL1 ERET. */
    uart_puts("Boot ROM: BL1 verified OK\n");
    prepare_el1_entry(bl1_scratch, header->image_size);
    eret_to_el1_secure(bl1_scratch);  // does not return

    return BOOT_SUCCESS;  /* unreachable */
}

/*
 * memcmp_constant_time: compare two buffers without early exit
 * Critical: a timing-variable comparison would allow an attacker to
 * oracle-attack the hash bit-by-bit using power analysis timing.
 */
int memcmp_constant_time(const uint8_t *a, const uint8_t *b, size_t len) {
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= a[i] ^ b[i];  // OR accumulates any difference
    }
    return diff;  // 0 if identical, non-zero if any byte differs
}
```

**Critical security properties of the above:**

- **Constant-time hash comparison:** A variable-time `memcmp` allows a timing oracle attack. The implementation ORs all differences into a single accumulator, taking identical time regardless of where the first mismatch occurs.
- **Key authentication before signature verify:** We verify the public key against OTP *before* using it. Without this, an attacker places their own key in flash with a self-signed BL1 image.
- **Signed header, anti-rollback checked after the signature:** The version field is only trustworthy once the signature that covers it has been verified. The signed digest includes every header field (magic, size, version, public key) as well as the image, so an old image cannot be relabelled with a newer version number.

---

### Step 4: Threat Model Analysis

**Threat 1: Physical attacker replaces BL1 on SPI flash with custom firmware.**

```
Attack steps:
1. Attacker reads SPI flash contents with a programmer.
2. Attacker modifies BL1 binary to add a back door.
3. Attacker re-signs BL1 with their own RSA key.
4. Attacker updates the public key in the BL1 header to their key.
5. Attacker reprograms the flash.

Boot ROM response:
Step 6 (key hash check): hw_sha256(attacker_key) ≠ oem_key_hash from OTP
→ Boot halts: "OEM key hash mismatch"

Result: Attack BLOCKED. The OTP hash is immutable (lock bits blown).
The attacker cannot change OTP without physical destruction of the device.
```

**Threat 2: Remote attacker exploits a vulnerability in the running OS and attempts to flash custom firmware via the OTA mechanism.**

```
Attack steps:
1. Attacker exploits a CVE in the Linux kernel (e.g., network stack bug).
2. Attacker gains root access in the Normal World.
3. Attacker calls the flash programming API to write malicious BL1 to SPI.
4. Attacker reboots the device, expecting to run malicious BL1.

Boot ROM response:
On next boot, Boot ROM reads flash and finds malicious BL1 (attacker cannot
sign it with OEM key). Step 9 (signature verify) fails.
→ Boot halts: "BL1 signature verification failed"

Additional countermeasure: The SPI flash write interface is memory-mapped
and access-controlled via TZPC — Normal World cannot write to the BL1
region of flash (offset 0x0000–0x3FFFF). Only a Secure World TA with
flash programming authority (provisioned by OEM) can write boot stages.

Result: Attack BLOCKED at two layers:
  Layer 1: SPI write blocked by TZPC (Normal World cannot write boot region)
  Layer 2: Even if flash were written, signature verification fails on next boot
```

**Threat 3: Attacker obtains an older, vulnerable firmware image and attempts a downgrade via the OTA channel.**

```
Attack scenario:
1. OEM discovers a critical vulnerability in BL2 version 3.
2. OEM releases BL2 version 4 that fixes the vulnerability.
3. All devices update via OTA to version 4.
4. OTP anti-rollback counter for BL2 is blown to 4 (minimum version = 4, so the vulnerable version 3 is also rejected)
   after all devices confirm update.
5. Attacker intercepts the OTA channel and attempts to deliver BL2 version 2.

Boot sequence response at Step 10 (anti-rollback check):
min_version_bl2 = otp_read_byte(OTP_ANTI_ROLLBACK + 1) → 4
header->version = 2 (the old, vulnerable version)
2 < 4 → Boot halts: "BL2 version below minimum (rollback attack)"

Result: Attack BLOCKED. The OTP counter reflects the burned minimum version;
the attacker cannot change OTP. Nor can the attacker edit the old image's header to
claim version 4 or higher: the version is inside the signed digest, so any change
fails signature verification before the anti-rollback check is reached.

Notes on OTA rollback procedure:
- OEM blows OTP anti-rollback counter ONLY after confirming a majority
  of devices have successfully updated (prevents bricking devices that
  failed the update).
- OTP fuse blowing is a one-way operation — you can increment the counter
  but never decrement. Version 2 will never boot on a device where the
  counter has been incremented past 2.
```

---

### Step 5: OTA Firmware Update Flow

An OTA update must be verified before being applied — applying an unverified update would bypass the chain of trust entirely.

**Update package format:**

```
OTA Package Structure:
┌───────────────────────────────────────────────────────────┐
│  OTA Manifest (signed JSON or CBOR)                       │
│  ─────────────────────────────────────────────────────    │
│  {                                                        │
│    "package_version": "4.2.1",                           │
│    "components": [                                        │
│      {                                                    │
│        "name": "BL2",                                    │
│        "version": 5,                                     │
│        "sha256": "a1b2c3....",                           │
│        "offset": 0x1000,                                 │
│        "size": 524288                                    │
│      },                                                   │
│      ...                                                  │
│    ],                                                     │
│    "signature": "RSA-2048-PSS over SHA-256(manifest_body)"│
│  }                                                        │
├───────────────────────────────────────────────────────────┤
│  BL2 binary (new version 5)                               │
├───────────────────────────────────────────────────────────┤
│  BL33 binary (new version)                                │
├───────────────────────────────────────────────────────────┤
│  Linux kernel FIT image (new version)                     │
└───────────────────────────────────────────────────────────┘
```

**OTA update procedure:**

```
Phase 1: Download and pre-verification (Normal World, but TEE-assisted)

1. Normal World OS downloads OTA package to a designated DRAM buffer.
2. Normal World invokes TEE TA via TEEC_InvokeCommand(TA_UUID_OTA, CMD_VERIFY_PACKAGE).
3. TEE TA receives the manifest pointer (validated address range, not Secure DRAM).
4. TEE TA verifies manifest signature using OEM public key (stored in TEE secure storage
   or verified against OTP hash).
5. TEE TA verifies SHA-256 of each component against manifest entries.
6. TEE TA checks all component version numbers against OTP anti-rollback counters.
7. If all checks pass, TEE TA returns VERIFIED status to Normal World.
   If any check fails, TEE TA returns error; Normal World aborts the update.

Phase 2: A/B partition write (atomic update)

8. The device uses A/B flash partitioning:
   Slot A: current running firmware (e.g., BL2 v4, kernel v3)
   Slot B: inactive slot (written during update)
   
9. Normal World's update daemon writes new components to Slot B.
   (The SPI flash controller allows Normal World to write to Slot B;
    the active Slot A is write-protected via TZPC during normal operation.)
    
10. After writing, Normal World invokes TEE TA again: CMD_VERIFY_WRITTEN_IMAGE.
11. TEE TA reads Slot B from flash and re-verifies SHA-256 of each component.
    This catches flash write errors.

Phase 3: Boot slot switch and verification boot

12. If Step 11 passes: TEE TA programs PMU/boot flags to boot from Slot B
    on next reset. Normal World requests reboot.
    
13. Boot ROM loads BL1 from Slot B and verifies signature. If OK, BL1 runs.
14. New firmware boots to a health check state. A countdown timer is set.
    If the device does not confirm successful boot within 60 seconds,
    the bootloader automatically reverts to Slot A on the next reboot.

15. If new firmware boots successfully:
    - Normal World confirms health: TEEC_InvokeCommand(CMD_CONFIRM_UPDATE)
    - TEE TA marks Slot B as verified; Slot A becomes the fallback.
    - If the update includes an OTP counter increment, the TEE TA now blows
      the anti-rollback fuse (only done AFTER confirming the new version works).

Phase 4: Rollback prevention

16. OTP anti-rollback counter is incremented (fuse blown) only in Phase 4,
    AFTER successful boot confirmation. This prevents a failed update from
    permanently bricking the device by incrementing the counter before the
    new image is confirmed bootable.
```

**Key security properties of this OTA flow:**

1. **Verification before write:** The update is verified in the TEE before touching flash. A corrupted or malicious package is rejected before any changes are made.

2. **Atomicity via A/B:** Either the full new firmware is verified and active, or the old firmware is active. There is no intermediate state where partially-updated firmware can boot.

3. **OTP increment timing:** Incrementing the anti-rollback counter is the last step, after confirming the new firmware boots. This is the safe ordering — a botched update that fails to boot leaves the counter unincremented, allowing a retry with the old firmware.

4. **TEE-controlled OTP access:** The OTP blow operation is only accessible from the TEE OTA TA, not from Normal World. A malicious app cannot increment the counter to brick the device.

---

## Summary Table

| Parameter | Value |
|---|---|
| Number of boot stages | 6 (ROM → BL1 → BL2 → BL31/BL32/BL33 → kernel) |
| Root key storage | SHA-256(RSA-2048 public key) in OTP[0:255] |
| Anti-rollback fields | 5 (BL1–BL33), 8 bits each (max version = 8) |
| Signature algorithm | RSA-2048-PSS with SHA-256 |
| OTP total size used | 320 bits of 512 available |
| A/B partition count | 2 (active + standby) |
| OTA verification location | TEE Trusted Application (Secure World) |
| OTP counter increment timing | After successful boot confirmation only |

## Key Takeaways

1. **The root of trust is only as strong as the OTP fuse protection.** Lock bits must be blown during manufacturing; an unlocked OTP allows an attacker to overwrite the key hash.

2. **Constant-time cryptographic comparisons are mandatory.** Variable-time comparisons in boot code are a known side-channel attack vector that has been exploited in real products.

3. **Anti-rollback counters must be incremented after, not before, confirming a successful update.** Blowing the fuse before the new image is confirmed bootable can leave a device with no image it is allowed to boot.

4. **A/B partitioning makes OTA atomic.** Atomic updates prevent the most dangerous firmware state: a partially-updated device that cannot boot either old or new firmware.

5. **Signature verification order and coverage matter.** Verify the key against OTP before using it, then verify the header and image against the key. Reversing the order allows an attacker to supply a self-signed image; leaving the header version unsigned lets an attacker relabel an old image and defeat anti-rollback.
