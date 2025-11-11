%!include ../../macros.md
# 16-bit Data Pointers on RV32

## Problem

Suppose we want to link this assembly file, `rv16.S`:

```
.global _start
_start:
    la a0, foobar_ptr
    lhu a0, (a0)
1:
    j 1b

foobar_ptr:
    .hword foobar

.section .bss
.global foobar
foobar:
    .word 0
```

Using this linker script, `rv16.ld`:

```
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text   : { *(.text) *(.text.*) }
    .rodata : { *(.srodata*) *(.rodata) *(.rodata.*) }
    .data   : { *(.sdata*) *(.data) *(.data.*) }
    .bss    : { *(.sbss*) *(.bss) *(.bss.*) }
}
```

The command line would look something like this:

```
riscv32-unknown-elf-gcc -c rv16.S
riscv32-unknown-elf-ld -T rv16.ld rv16.o -o rv16.elf
```

But the assembler reports an error like:

```
rv16.S:9: Error: cannot represent BFD_RELOC_16 relocation in object file
```

## Explanation

The assembler is upset about this line:

```
.hword foobar
```

This is because we have asked it to create a 16-bit relocation for a pointer, and it doesn't know how to do that, or refuses to. This is a reasonable type of relocation to emit if your binary is linked in the lower 64%!kbyte of the address space, and you can save a lot of storage for pointer literals if you don't store each of them with 16 bonus bits that are always zero. For example, SoC boot ROMs are usually small, statically linked at a known address, and extremely sensitive to static code size. This is easy to do with the `arm-none-eabi` GNU toolchain (you just get a linker error if the pointer loses bits due to truncation), but impossible with RISC-V GNU and LLVM toolchains.

As far as I can tell a suitable relocation does exist in the [RISC-V ELF PSABI](https://github.com/riscv-non-isa/riscv-elf-psabi-doc/releases/download/v1.0/riscv-abi.pdf): a normal 32-bit data relocation `.word foobar` would be emitted as an `R_RISCV_32`, and here we could just use an `R_RISCV_ADD16` with an initial value of 0. I asked a friend who is an expert on the RISC-V `lld` backend and he mumbled something about linker relaxation while staring into the distance, his eyes clouded and unfocused. I left him to his contemplation and figured out a way to make the linker do what I want using brute force.

## One Weird Trick, Linker Engineers Hate It

`gas` will happily emit 16-bit relocations for a difference of two symbols, using a matched pair of `R_RISCV_ADD16` and `R_RISCV_SUB16` relocations.

```
.global _start
_start:
    la a0, foobar_ptr
    lhu a0, (a0)
1:
    j 1b

foobar_ptr:
    .hword foobar - wibble

.section .bss.foobar
.global foobar
foobar:
    .word 0

.section .bss.wibble
.global wibble
wibble:
    .word 0
```

Assembling and then disassembling with relocations:

```
luke@cube tmp % riscv32-unknown-elf-gcc -c rv16.S && riscv32-unknown-elf-objdump -dr rv16.o

rv16.o:     file format elf32-littleriscv


Disassembly of section .text:
...
00000010 <foobar_ptr>:
    10: 0000                .short 0x0000
10: R_RISCV_ADD16 foobar
10: R_RISCV_SUB16 wibble
```

So the problem is reduced to: "how can we use relative relocations to assemble absolute ones?" My hack is to add this to the linker script:

```
SECTIONS
{
...
    PROVIDE(__opaque_zero_symbol = 0);
}
```

And modify 16-bit pointers in the source like so:

```
foobar_ptr:
    .hword foobar - __opaque_zero_symbol
```

This now assembles and links as expected. The relocations in the object file are:

```
00000010 <foobar_ptr>:
    10: 0000                .short 0x0000
10: R_RISCV_ADD16 foobar
10: R_RISCV_SUB16 __opaque_zero_symbol
```

Subtracting zero is a no-op, so this is effectively an absolute relocation.
