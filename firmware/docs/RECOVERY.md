# Recovery (pre-flash — validation status)

## Available now (validated)

1. **Serial shell** via UART bridge @ 115200 8N1 — login `root` with the device password you set (never commit it).
2. **Full flash backup** (read-only dump) kept in a **private local** directory such as `uart-bridge/backups/` (gitignored).  
   Reference SHA-256 for one verified 16 MiB dump:  
   `5339528331f1c80c378c02e00290d68e799cb13da421a1a2a92ca29b45c979bb`
3. **Per-partition images** alongside that backup (`mtdblock*_*.bin`).
4. **Fanghacks SD** still boots scripts from card — primary development/recovery path until internal install.

## Stock rescue partition (mtd3)

- Present (4 MiB) and **retained** in layout.
- Contents are **vendor rescue — not sanitized**, not tested as recovery boot in this project yet.
- Do **not** claim rescue boot works until exercised over serial.

## Alternate RAM/SD boot via U-Boot

- **Status: UNVALIDATED**
- Do not guess addresses, image formats, or checksum algorithms.
- Before first internal write: capture `help`, `printenv`, and any documented SONiX/SN9 boot notes from serial at U-Boot prompt (requires interrupting boot — physical timing).

## Intended restore procedure (after validation)

1. Enter U-Boot or use vendor flash tool **only with verified commands**.
2. Restore `mtd2` (rootfs) and/or `mtd4` (etc) from backup hashes.
3. **Never** routine-restore `mtd0` uboot / `mtd3` rescue / `mtd5` userconfig unless disaster recovery explicitly requires it.

## Before first internal flash write (gate)

Present to operator: image paths, sizes, SHA-256, partitions touched, test results, install steps, and this recovery status.
