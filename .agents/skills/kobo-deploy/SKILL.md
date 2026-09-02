---
name: kobo-deploy
description: >-
  Build, verify, and deploy KOReader plugins and native shared libraries to a USB-connected Kobo device. Use when the user requests building libmicrotex.so, deploying plugins, verifying ELF binary compatibility for Kobo Libra 2, or running deploy.sh.
---

# Kobo Deployment and Binary Verification Runbook

This skill outlines the standard workflow for cross-compiling the native math library, validating ARMv7 ELF binary compatibility for the Kobo Libra 2, and deploying plugins to the physical device.

---

## 1. Prerequisites Check

1. Verify Zig is installed and available in `PATH`:
   ```bash
   which zig || mise which zig
   ```
   If missing, install via Mise:
   ```bash
   mise install zig
   ```

2. Verify the Kobo device is connected:
   ```bash
   lsblk -f | grep -i KOBOeReader
   ```

---

## 2. Cross-Compilation (MicroTeX)

To build `libmicrotex.so` targeting glibc 2.19 on ARMv7:

```bash
cd plugins/markdownreader.koplugin
make clean
make KOBO_CXX="zig c++ -target arm-linux-gnueabihf.2.19" kobo
mv kobo-libmicrotex.so libmicrotex.so
cd ../..
```

---

## 3. Pre-Deployment Binary Verification

Before deploying `libmicrotex.so` to the device, execute these four checks to guarantee the binary will not crash the dynamic linker (`ld-linux-armhf.so.3`) or trigger a teardown segfault:

```bash
cd plugins/markdownreader.koplugin

# Check 1: Absence of unsupported relocations (R_ARM_REL32, 0x03, 0x6c, 0x54)
# Must return empty.
readelf -r libmicrotex.so | grep -E 'R_ARM_REL32|0x03|0x6c|0x54'

# Check 2: glibc symbol version bounds (must be <= GLIBC_2.19)
readelf -V libmicrotex.so | grep GLIBC_

# Check 3: Dynamic flags (must include NODELETE and SysV HASH)
readelf -d libmicrotex.so | grep -E 'FLAGS|NODELETE|HASH'

# Check 4: RELRO neutralization (must return empty)
readelf -l libmicrotex.so | grep GNU_RELRO

cd ../..
```

---

## 4. Execute Deployment

Run the automated deployment script:

```bash
./deploy.sh
```

The script will:
1. Compile `libmicrotex.so` if toolchains are present.
2. Locate and mount the Kobo device partition (`KOBOeReader`).
3. Purge stale rendered formula SVG caches (`.rendered/`, `math_svg/`) and HTML caches.
4. Copy updated plugins into `.adds/koreader/plugins/`.
5. Sync secrets into `.adds/koreader/settings/`.
6. Flush filesystem buffers (`sync`).

---

## 5. Post-Deployment Verification

Check that the files on the mounted device are updated:
```bash
find /home/denial/Mount/KOBO/.adds/koreader/plugins/markdownreader.koplugin -maxdepth 1 -name "libmicrotex.so" -ls
```
Once verified, inform the user that it is safe to eject/disconnect the device.
