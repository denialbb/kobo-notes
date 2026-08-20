# MicroTeX Dynamic Library Integration and Runtime Compatibility on Kobo Libra 2 (glibc 2.19 / LuaJIT FFI)

## 1. Technical Context & Platform Constraints

Building and executing **MicroTeX** (`libmicrotex.so`, a C++17 LaTeX math typesetting library derived from cLaTeXMath) as a native dynamic shared object for KOReader on the **Kobo Libra 2** requires satisfying strict target platform constraints:

- **Target Architecture**: 32-bit ARMv7-A (`arm-linux-gnueabihf`), Cortex-A9 core, NEON SIMD, hard-float ABI (`-mfloat-abi=hard`).
- **Target OS & Dynamic Linker**: Embedded Linux kernel 4.1.15 with **glibc 2.19** (`/lib/ld-linux-armhf.so.3`, `/lib/libc.so.6`, `/lib/libm.so.6`).
- **Host Application**: KOReader (running LuaJIT 2.1). Dynamic libraries are loaded in-process via LuaJIT Foreign Function Interface (`ffi.load` / `dlopen`).
- **Vector Rendering**: Crengine renders document layout and parses inline/block SVG formula output via its embedded **NanoSVG** engine.

---

## 2. Failure Modes & Root Cause Analysis

### 2.1 Unsupported Dynamic Relocations (`unexpected reloc type 0x03`, `0x6c`, `0x54`)

- **Symptom**: `ffi.load("/mnt/onboard/.../libmicrotex.so")` failed at runtime with:
  ```text
  ffi.load failed: unexpected reloc type 0x03
  ```
  or secondary failures reporting relocation types `0x6c` and `0x54`.
- **Root Causes**:
  1. `0x03` corresponds to `R_ARM_REL32`, a static PC-relative relocation emitted when translation units are compiled without position-independent code flags (`-fPIC`). Static PC-relative relocations cannot be resolved at dynamic link time in ELF shared objects.
  2. `0x6c` (`R_ARM_TLS_DESC`) and `0x54` (`R_ARM_THM_JUMP19`) are relocation types emitted by modern Clang/LLD and GCC toolchains. The glibc 2.19 dynamic loader (`ld-linux-armhf.so.3`) on the device lacks support for these relocation types.
  3. LLD emits `PT_GNU_RELRO` program headers and section layouts that cause legacy ARM glibc loaders to fail during relocation processing.

### 2.2 glibc Symbol Version Mismatches (`GLIBC_2.29 not found`)

- **Symptom**: Binaries cross-compiled using modern ARM GCC toolchains (e.g., GCC 13.3) failed on `ffi.load` with:
  ```text
  /lib/libm.so.6: version `GLIBC_2.29' not found (required by libmicrotex.so)
  ```
- **Root Cause**: Modern toolchain sysroots resolve standard mathematical functions (`powf`, `expf`, `logf`) against `GLIBC_2.29` symbol versions. The system `libm.so.6` on Kobo firmware only exports symbol versions up to `GLIBC_2.19`.

### 2.3 Teardown Segmentation Fault on USB Mass Storage Mode (`exit code: 86`)

- **Symptom**: When entering USB Mass Storage mode (USBMS), KOReader invokes `os.exit(86, true)` to close the Lua state (`lua_close(L)`). When `libmicrotex.so` had been loaded and executed during the session, process termination triggered a `Segmentation fault`.
- **Root Causes**:
  1. **Dynamic `__cxa_atexit` Destructors**: Compilers defaulting to `__cxa_atexit` register dynamic teardown handlers with glibc. During process exit on glibc 2.19 ARM, traversing dynamic destructor tables after Lua state teardown caused invalid memory dereferences.
  2. **DSO Unmapping via `dlclose`**: `lua_close(L)` unloads FFI shared libraries. Unmapping DSO memory while static references or thread structures remained active resulted in memory faults.
  3. **Unmanaged Static Singletons**: MicroTeX initializes global font tables and formula parsers (`DefaultTeXFont`, `Formula`, `MacroInfo`). Without an explicit teardown hook before process termination, lingering references conflicted with glibc finalization.

---

## 3. Toolchain & Build Implementation

To eliminate external legacy sysroot requirements and guarantee strict ABI conformance, cross-compilation uses **`zig c++`** targeting glibc 2.19.

### 3.1 Targeted Toolchain Invocation

```bash
make KOBO_CXX="zig c++ -target arm-linux-gnueabihf.2.19"
```

Zig provides hermetic symbol version definitions for `arm-linux-gnueabihf.2.19`. Imported glibc/libm symbols are strictly constrained to `GLIBC_2.4`, `GLIBC_2.7`, `GLIBC_2.16`, and `GLIBC_2.19`.

### 3.2 Compilation & Linker Flags

```makefile
CXXFLAGS = -std=c++17 -mcpu=cortex_a9 -mfpu=neon -mfloat-abi=hard -fPIC -fno-use-cxa-atexit -I./microtex/src -I. -O2
LDFLAGS  = -shared -Wl,--hash-style=sysv -Wl,-z,norelro -Wl,-z,nodelete -Wl,-T,kobo.ld
```

- **`-fPIC`**: Enforces position-independent code across all translation units, preventing `R_ARM_REL32` (`0x03`).
- **`-fno-use-cxa-atexit`**: Emits static destructors into `.fini_array` sections instead of registering runtime handlers via glibc `__cxa_atexit`, avoiding glibc 2.19 exit crashes.
- **`-Wl,-z,nodelete`**: Sets the `DF_1_NODELETE` dynamic flag in `DT_FLAGS_1`. The dynamic linker will not unmap DSO memory during `dlclose()` / `lua_close(L)`, preventing segmentation faults during `os.exit(86, true)`.
- **`-Wl,--hash-style=sysv`**: Generates traditional SysV ELF hash tables (`.hash`) required by glibc 2.19.
- **`-Wl,-z,norelro`**: Prevents standard GNU RELRO segment layout generation.

### 3.3 Linker Script (`kobo.ld`)

The custom linker script orders relocation and exception sections prior to `.text`:

```ld
SECTIONS
{
  .rel.dyn : { *(.rel.dyn) }
  .rel.plt : { *(.rel.plt) }
  .ARM.exidx : { *(.ARM.exidx) }
}
INSERT BEFORE .text;
```

### 3.4 RELRO Program Header Neutralization (`fix_relro.py`)

LLD may still generate a `PT_GNU_RELRO` program header entry despite `-Wl,-z,norelro`. `fix_relro.py` inspects the ELF program header table and patches `p_type` from `0x6474e552` (`PT_GNU_RELRO`) to `0x0` (`PT_NULL`):

```python
import sys, struct

def remove_relro(filepath):
    with open(filepath, 'r+b') as f:
        elf = f.read(52)
        phoff = struct.unpack('<I', elf[28:32])[0]
        phentsize = struct.unpack('<H', elf[42:44])[0]
        phnum = struct.unpack('<H', elf[44:46])[0]
        for i in range(phnum):
            f.seek(phoff + i * phentsize)
            phdr = f.read(phentsize)
            ptype = struct.unpack('<I', phdr[0:4])[0]
            if ptype == 0x6474e552:  # PT_GNU_RELRO
                f.seek(phoff + i * phentsize)
                f.write(struct.pack('<I', 0))  # PT_NULL
                return
```

### 3.5 Explicit Lifecycle Cleanup

- **C Interface (`api.cpp`)**:
  ```cpp
  void microtex_release() {
      try {
          tex::LaTeX::release();
      } catch (...) {}
  }
  ```
- **LuaJIT FFI (`math_backend_microtex.lua`)**:
  Exposes `MicroTex.release()`, which invokes `lib.microtex_release()` to free font resources prior to KOReader process shutdown.

---

## 4. Verification and Validation Procedures

Run the following inspection commands on the built `libmicrotex.so` before deployment:

1. **Verify Absence of Unsupported Relocations**:
   ```bash
   readelf -r libmicrotex.so | grep -E 'R_ARM_REL32|0x03|0x6c|0x54'
   ```
   *Expected output: Empty (zero matches).*

2. **Verify glibc Symbol Version Bounds**:
   ```bash
   readelf -V libmicrotex.so | grep GLIBC_
   ```
   *Expected output: Only symbol versions <= `GLIBC_2.19` (e.g. `GLIBC_2.4`, `GLIBC_2.7`, `GLIBC_2.16`, `GLIBC_2.19`). No `GLIBC_2.29+` entries.*

3. **Verify Dynamic Flags**:
   ```bash
   readelf -d libmicrotex.so | grep -E 'FLAGS|NODELETE|HASH'
   ```
   *Expected output: Dynamic section contains `FLAGS_1: NODELETE` (or `Flags: NOW NODELETE`) and `HASH` (SysV hash).*

4. **Verify RELRO Neutralization**:
   ```bash
   readelf -l libmicrotex.so | grep GNU_RELRO
   ```
   *Expected output: Empty (zero matches; header converted to `PT_NULL`).*

5. **On-Device Execution Verification**:
   - `ffi.load(so_path)` completes without error.
   - LaTeX mathematical expressions render to SVG markup in `.rendered/math_svg/*.svg`.
   - Crengine renders SVG markup accurately via NanoSVG.
   - Triggering USB Mass Storage mode exits cleanly (`exit code: 86`) without segmentation faults.

---

## 5. Architectural References

- [ADR 0001: Cross-compiling MicroTeX with Zig for Kobo glibc 2.19 Compatibility](./adr/0001-zig-cross-compilation-for-kobo-glibc.md)
- [Context Map](../CONTEXT-MAP.md)
- [Markdown & Math Rendering Context](../plugins/markdownreader.koplugin/CONTEXT.md)

