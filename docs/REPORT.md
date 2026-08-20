# Report: MicroTeX Library Load Failure on KOReader (Kobo Libra 2)

## Summary

An attempt to load a MicroTeX shared library via LuaJIT’s Foreign Function Interface (`ffi.load`) on KOReader running on a Kobo Libra 2 produces the error:

```
ffi.load failed, unexpected reloc type 0x
```

(typically completed as `0x03`). This is a dynamic-linker rejection of an invalid relocation type inside a shared object on 32-bit ARM.

## Device and Environment Context

- **Device**: Kobo Libra 2
- **Architecture**: 32-bit ARMv7 (`arm-linux-gnueabihf`, hard-float)
- **Software**: KOReader (LuaJIT-based)
- **Library**: MicroTeX (C++ LaTeX math rendering engine by NanoMichael)

KOReader loads native libraries through LuaJIT’s `ffi.load`, which ultimately calls the system dynamic linker (`dlopen`). The Kobo platform uses an older glibc/kernel combination that strictly enforces allowed relocation types for shared objects.

## Technical Cause

Relocation type `0x03` corresponds to `R_ARM_REL32` on ARM ELF.

- `R_ARM_REL32` is a **static** relocation.
- The dynamic loader rejects it inside a shared library (`.so`).
- The presence of this relocation almost always indicates that one or more object files were compiled **without** `-fPIC` (Position-Independent Code) and then linked into a shared object.

This behaviour is well-documented on ARM Linux:

> “Relocation type 3 is R_ARM_REL32 which is a static relocation not allowed in shared objects. … Make sure you compile all the code going into it with -fPIC.”  
> — Stack Overflow / Linaro toolchain discussion (https://stackoverflow.com/questions/33474070/unexpected-reloc-type-0x03)

A related Crypto++ issue on ARM shows the identical error message when an assembly or C object containing `R_ARM_REL32` is placed in a shared library (https://github.com/weidai11/cryptopp/issues/846).

## Why This Occurs with MicroTeX

MicroTeX (https://github.com/NanoMichael/MicroTeX) is a pure C++ library that must be built as a shared object for use with LuaJIT FFI. If the library (or any of its dependencies) is:

- built on an x86_64 host without a proper cross-compiler,
- compiled without `-fPIC`,
- linked with incorrect flags, or
- taken from a pre-built binary intended for a different ABI,

the resulting `.so` will contain illegal relocations and fail exactly as observed.

KOReader’s own documentation and community discussions confirm that custom `.so` files must be built for the target device’s ABI (ARM 32-bit for most Kobos) and placed in the `libs/` search path used by the FFI loader.

## Required Correct Build

A working library must be cross-compiled with a toolchain matching KOReader’s (arm-linux-gnueabihf) and the following essential flags:

```text
-fPIC
-march=armv7-a -mfpu=neon -mfloat-abi=hard
-shared   (at link time)
```

Every translation unit that ends up in the final shared object must be compiled with `-fPIC`. After building, the library can be verified on a host with:

```bash
arm-linux-gnueabihf-objdump -R libmicrotex.so | grep -E 'R_ARM_REL32|0x03'
```

Any remaining `R_ARM_REL32` entries indicate the build is still incorrect.

## Recommended Actions for the Agent

1. Confirm the exact path and filename being passed to `ffi.load`.
2. Obtain or rebuild MicroTeX using a proper arm-linux-gnueabihf cross-toolchain with `-fPIC` on all objects.
3. Place the resulting shared library in KOReader’s `libs/` directory (or the path expected by the calling plugin).
4. Verify the absence of illegal relocations before deploying to the device.
5. If a third-party plugin supplies a pre-built binary, discard it and replace it with a correctly cross-compiled version.

## Sources

- Stack Overflow – “unexpected reloc type 0x03” (ARM shared library / -fPIC requirement):  
  https://stackoverflow.com/questions/33474070/unexpected-reloc-type-0x03

- Crypto++ GitHub issue #846 – identical error on ARM caused by `R_ARM_REL32`:  
  https://github.com/weidai11/cryptopp/issues/846

- MicroTeX upstream repository:  
  https://github.com/NanoMichael/MicroTeX

- LuaJIT FFI documentation (`ffi.load`):  
  https://luajit.org/ext_ffi_api.html

- KOReader Kobo installation and library-loading behaviour (community and wiki references confirming ARM ABI requirements for custom shared objects).
