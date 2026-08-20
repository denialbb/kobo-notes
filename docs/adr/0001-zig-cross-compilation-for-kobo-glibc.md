# Cross-compiling MicroTeX with Zig for Kobo glibc 2.19 Compatibility

Cross-compile the native MicroTeX LaTeX math rendering library (`libmicrotex.so`) for KOReader on Kobo devices using `zig c++` targeting `arm-linux-gnueabihf.2.19` with explicit ELF section ordering and dynamic flags to satisfy legacy glibc 2.19 loader constraints and eliminate exit-time segmentation faults.

## Context

KOReader on Kobo hardware (such as the Kobo Libra 2) runs on a 32-bit ARMv7-A Linux environment with `glibc 2.19`. Loading native C++ dynamic shared objects via LuaJIT FFI (`ffi.load` / `dlopen`) encounters three critical runtime failure modes:

1. **glibc Symbol Version Incompatibility**: Modern GCC and Clang sysroots bind mathematical functions (`powf`, `expf`, `logf`) to `GLIBC_2.29` symbols, which do not exist in Kobo firmware `/lib/libm.so.6`.
2. **Unsupported Relocations and Headers**: Modern linkers emit relocations (`R_ARM_REL32` / `0x03` if missing `-fPIC`, `R_ARM_TLS_DESC` / `0x6c`, `R_ARM_THM_JUMP19` / `0x54`) and `PT_GNU_RELRO` program headers that the glibc 2.19 dynamic loader (`ld-linux-armhf.so.3`) rejects at load time.
3. **Exit Teardown Segmentation Fault**: When KOReader transitions to USB Mass Storage mode, it invokes `os.exit(86, true)` to close the Lua state (`lua_close(L)`). Dynamic `__cxa_atexit` destructor registration and premature dynamic shared object unmapping via `dlclose()` cause segmentation faults during process finalization.

## Decision

We cross-compile `libmicrotex.so` using `zig c++ -target arm-linux-gnueabihf.2.19` with a pinned toolchain configuration:

1. **ABI Version Bounding**: `-target arm-linux-gnueabihf.2.19` hermetically restricts all imported symbols to versions supported by Kobo glibc 2.19 (`GLIBC_2.4` through `GLIBC_2.19`).
2. **Position-Independent Code**: `-fPIC` prevents static PC-relative relocations (`R_ARM_REL32`).
3. **ELF Header and Relocation Layout**:
   - `kobo.ld` linker script orders `.rel.dyn`, `.rel.plt`, and `.ARM.exidx` before `.text`.
   - `fix_relro.py` patches leftover `PT_GNU_RELRO` program headers (`0x6474e552`) to `PT_NULL` (`0x0`).
   - `-Wl,--hash-style=sysv` and `-Wl,-z,norelro` ensure classic SysV hash tables and prevent incompatible RELRO segments.
4. **Exit Crash Prevention**:
   - `-fno-use-cxa-atexit`: Places static destructors into `.fini_array` instead of registering dynamic handlers with glibc `__cxa_atexit`.
   - `-Wl,-z,nodelete`: Sets `DF_1_NODELETE` on `DT_FLAGS_1` so dynamic memory pages are never unmapped during `lua_close(L)`.
   - Explicit `microtex_release()` hook calling `tex::LaTeX::release()` to free static singletons before process exit.

## Consequences

- `libmicrotex.so` compiles deterministically without requiring an external legacy GCC sysroot.
- The shared object loads reliably via LuaJIT `ffi.load` on Kobo hardware running glibc 2.19.
- USB storage transitions execute `os.exit(86, true)` cleanly without process crashes.

