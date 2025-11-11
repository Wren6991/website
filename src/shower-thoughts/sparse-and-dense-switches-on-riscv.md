%!include ../../macros.md
# Sparse and Dense Switches on %!riscv

This post looks at a couple of size tricks used in the [RP2350 bootrom](https://github.com/raspberrypi/pico-bootrom-rp2350). There is one trick for **sparse** and one trick for **dense** case statements.

That bootrom has some pretty gnarly size hacks because it has to fit a lot of functionality into a 32%!kbyte mask ROM, and execute on both Arm and %!riscv. These two tricks are on the more generally useful end of the spectrum; you can apply them in your own hand-written %!riscv code if you are tight on space.

For the purpose of this post we are interested only in static code size. Performance benchmarking is for nerds.

## PC-relative Compressed Instructions

The %!riscv C extension has relatively few instructions which observe or modify the program counter:

* `c.j`: set `pc` = `pc + imm` (range of 2%!kbyte)

* `c.jal`: set `ra` = `pc + 2`; set `pc = pc + imm` (range of 2%!kbyte)

* `c.jalr`: set `ra` = `pc + 2`; set `pc = rs1` (`rs1` is any `x` register except `zero`)

* `c.jr`: set `pc = rs1` (`rs1` is any `x` register except `zero`)

* `c.beqz`: if `rs1` is zero, set `pc = pc + imm` (`rs1` is in `x8`-`x15`, range of 256%!byte)

* `c.bnez`: if `rs1` is nonzero, set `pc = pc + imm` (`rs1` is in `x8`-`x15`, range of 256%!byte)

That's it. One painful omission is a 16-bit counterpart for `auipc`, like `lda` from Thumb; in fact the only 16-bit instructions that write a PC-relative value into a GPR are `c.jal` and `c.jalr`, and you can bet we will make use of this fact.

There are also the `cm.popret` and `cm.popretz` instructions from Zcmp, but they are mostly irrelevant for this post. We'll stick to the RV32IC dialect.

## Sparse Case Statements

A sparse case statement is one where the case items are not numerically consecutive. Say I want to select one of five integers depending on whether an upper-case letter appears in my name:

```c
// Still a better workload than Dhrystone
int is_luke(char x, int a, int b, int c, int d, int e) {
    switch (x) {
        case 'L': return a;
        case 'U': return b;
        case 'K': return c;
        case 'E': return d;
        default:  return e;
    }
}
```

You can look at that code on Godbolt [here](https://godbolt.org/z/qxdTb5vdG) but I'm going to use `objdump` output because it makes the instruction sizes more visually obvious. All compilation in this post is with GCC 15.1.0.

```
$ riscv32-unknown-elf-gcc -march=rv32ic -Os -c sparse-case.c
$ riscv32-unknown-elf-objdump -d sparse-case.o

sparse-case.o:     file format elf32-littleriscv


Disassembly of section .text:

00000000 <is_luke>:
   0:   04c00813        li      a6,76
   4:   03050563        beq     a0,a6,2e <.L4>
   8:   00a86d63        bltu    a6,a0,22 <.L3>
   c:   04500613        li      a2,69
  10:   02c50163        beq     a0,a2,32 <.L5>
  14:   04b00713        li      a4,75
  18:   00e51363        bne     a0,a4,1e <.L2>
  1c:   87b6            mv      a5,a3

0000001e <.L2>:
  1e:   853e            mv      a0,a5
  20:   8082            ret

00000022 <.L3>:
  22:   05500713        li      a4,85
  26:   fee51ce3        bne     a0,a4,1e <.L2>
  2a:   87b2            mv      a5,a2
  2c:   bfcd            j       1e <.L2>

0000002e <.L4>:
  2e:   87ae            mv      a5,a1
  30:   b7fd            j       1e <.L2>

00000032 <.L5>:
  32:   87ba            mv      a5,a4
  34:   b7ed            j       1e <.L2>

```

The compiler output is fairly straightforward: load each comparison constant in turn. If it compares equal to `x` (passed in `a0`), then branch to a subroutine that returns the correct integer `a` through `e` (passed in `a1` through `a5`). One neat detail is that it actually searches in a binary tree instead of going through the cases one by one; the first value it checks is `76`, or ASCII `L`, so `U` is above it and `K` and `E` are below it.

The important thing to notice in that disassembly is that the instructions in the branch tree are _all 32-bit instructions._

To make this smaller, think back to our compressible instructions: the only conditional branches are comparisons for equal/not equal to zero, so we need to transform the comparisons into this form. We can do this by adding a series of differences to `a0` so that it is zero when the initial value was equal to our case item:

```
is_luke:
    addi a0, a0, -'E'
    beqz a0, 1f
    addi a0, a0, 'E'-'K'
    beqz a0, 2f
    addi a0, a0, 'K'-'L'
    beqz a0, 3f
    addi a0, a0, 'L'-'U'
    beqz a0, 4f
0:
    mv a0, a5
    ret
1:
    mv a0, a1
    ret
2:
    mv a0, a2
    ret
3:
    mv a0, a3
    ret
4:
    mv a0, a4
    ret
```

These are all 16-bit instructions, except for the very first instruction which subtracts `69`; `c.addi` has a range of `-32` to `31`. We can check this by assembling and disassembling:


```
$ riscv32-unknown-elf-gcc -march=rv32ic -c sparse-case.S
$ riscv32-unknown-elf-objdump -d sparse-case.o          

sparse-case.o:     file format elf32-littleriscv


Disassembly of section .text:

00000000 <is_luke>:
   0:   fbb50513        addi    a0,a0,-69
   4:   c909            beqz    a0,16 <.L1^B1>
   6:   1569            addi    a0,a0,-6
   8:   c909            beqz    a0,1a <.L2^B1>
   a:   157d            addi    a0,a0,-1
   c:   c909            beqz    a0,1e <.L3^B1>
   e:   155d            addi    a0,a0,-9
  10:   c909            beqz    a0,22 <.L4^B1>
  12:   853e            mv      a0,a5
  14:   8082            ret

00000016 <.L1^B1>:
  16:   852e            mv      a0,a1
  18:   8082            ret

0000001a <.L2^B1>:
  1a:   8532            mv      a0,a2
  1c:   8082            ret

0000001e <.L3^B1>:
  1e:   8536            mv      a0,a3
  20:   8082            ret

00000022 <.L4^B1>:
  22:   853a            mv      a0,a4
  24:   8082            ret
```

The compiler output is 36 bytes, and the hand-written code is 26 bytes, for a 28% reduction.

## Dense Case Statements

Hopefully you found that agreeable. The next one is uglier. I mentioned earlier that `c.jalr` and `c.jal` are the only compressed instructions which write a PC-relative value to a GPR.

A dense case statement is one where the case items are all consecutive (my definition). Say we want to apply one of several operations to a pair of integers based on some opcode ([Godbolt link](https://godbolt.org/z/d1d7sGcbP)):

```c
int alu(int op, int a, int b) {
    switch (op & 0x7) {
        case 0: return a + b;
        case 1: return a - b;
        case 2: return a & b;
        case 3: return a | b;
        case 4: return a ^ b;
        case 5: return a >> b;
        case 6: return a << b;
        case 7: return ~a;
        default: __builtin_unreachable();
    }
}
```

The compiler output is:

```
$ riscv32-unknown-elf-gcc -march=rv32ic -Os -c dense-case.c 
$ riscv32-unknown-elf-objdump -d dense-case.o

dense-case.o:     file format elf32-littleriscv


Disassembly of section .text:

00000000 <alu>:
   0:   891d            andi    a0,a0,7
   2:   157d            addi    a0,a0,-1
   4:   4799            li      a5,6
   6:   00a7ea63        bltu    a5,a0,1a <.L2>
   a:   000007b7        lui     a5,0x0
   e:   00078793        mv      a5,a5
  12:   050a            slli    a0,a0,0x2
  14:   953e            add     a0,a0,a5
  16:   411c            lw      a5,0(a0)
  18:   8782            jr      a5

0000001a <.L2>:
  1a:   00c58533        add     a0,a1,a2
  1e:   8082            ret

00000020 <.L10>:
  20:   40c58533        sub     a0,a1,a2
  24:   8082            ret

00000026 <.L9>:
  26:   00c5f533        and     a0,a1,a2
  2a:   8082            ret

0000002c <.L8>:
  2c:   00c5e533        or      a0,a1,a2
  30:   8082            ret

00000032 <.L7>:
  32:   00c5c533        xor     a0,a1,a2
  36:   8082            ret

00000038 <.L6>:
  38:   40c5d533        sra     a0,a1,a2
  3c:   8082            ret

0000003e <.L5>:
  3e:   00c59533        sll     a0,a1,a2
  42:   8082            ret

00000044 <.L3>:
  44:   fff5c513        not     a0,a1
  48:   8082            ret
```

This is mostly just performing a 32-bit lookup with `a0 & 0x7` as an index. `a0` is the `op` operand to our original C function. I'm not quite sure why it does the initial branch for `> 6`; it might be vestigial from the default case, if the compiler doesn't realise that the case is fully populated due to the AND on `op`.

The `lui`; `mv` pair is actually getting the absolute address of a table of 32-bit pointers in `.rodata`:

```
$ riscv32-unknown-elf-objdump -dr -j .rodata dense-case.o

Disassembly of section .rodata:

00000000 <.L4>:
        ...
                 0: R_RISCV_32   .L10
                 4: R_RISCV_32   .L9
                 8: R_RISCV_32   .L8
                 c: R_RISCV_32   .L7
                 10: R_RISCV_32  .L6
                 14: R_RISCV_32  .L5
                 18: R_RISCV_32  .L3
```

I have two observations about this code:

* Full 32-bit pointers are expensive given the labels we are branching to are very close to the top of the switch statement.
* The code to look up a 32-bit table entry is itself quite bulky.

Here is an alternative approach:

```
alu:
    mv t1, ra
    andi t0, a0, 0x7
    jal table_branch_byte
alu_op_table:
    .byte 0f - alu_op_table
    .byte 1f - alu_op_table
    .byte 2f - alu_op_table
    .byte 3f - alu_op_table
    .byte 4f - alu_op_table
    .byte 5f - alu_op_table
    .byte 6f - alu_op_table
    .byte 7f - alu_op_table
0:  add a0, a1, a2
    jr t1
1:  sub a0, a1, a2
    jr t1
2:  and a0, a1, a2
    jr t1
3:  or a0, a1, a2
    jr t1
4:  xor a0, a1, a2
    jr t1
5:  sra a0, a1, a2
    jr t1
6:  srl a0, a1, a2
    jr t1
7:  not a0, a1
    jr t1

table_branch_byte:
    add t0, t0, ra
    lbu t0, (t0)
    add t0, t0, ra
    jr t0
```

This assembles to 74 bytes, including the jump table. What's more, the `table_branch_byte` subroutine (10 bytes) can be shared among multiple functions. The compiler version is 106 bytes, including the jump table (minus a potential 6 bytes for linker relaxation of the non-position-independent table reference).

The `table_branch_byte` routine takes the following steps:

* Look up index `t0` (which is `op & 0x7`) relative to `alu_op_table`.
* Load that branch offset from that index of the table.
* Add the loaded branch offset to `alu_op_table`.
* Jump to `alu_op_table` plus the loaded branch offset.

This trashes `ra` but you are likely to have it on the stack already -- it's pushed for "free" by any `cm.push` and popped by any `cm.pop*`.

See [here](https://github.com/raspberrypi/armulet/blob/a95adb4e3a92ca6add831e6e742d824cd5b956f6/varmulet/varmulet_armv6m_core.S#L1029-L1037) for an example of this trick being used in the RP2350 bootrom. There are some macros in use to cut down on wear and tear on the programmer's keyboard.

## Bonus Trick: Constant Islands in Functions

%!riscv avoids emitting constants in `.text` sections because, among other reasons, it makes it difficult to mark `.text` as execute-only for security purposes. What if we didn't care about security? What if we were just nice to each other?

Say we wanted to zero a list of memory regions during startup:

```
.p2align 2
    jal a1, 1f
.word __bss_start, __bss_end
.word __heap_start, __heap_end
.word 0
1:
    lw a0, (a1)
    beqz a0, 3f
    lw a1, 4(a1)
    bgeu a0, a1, 3f
2:
    sw zero, (a0)
    addi a0, a0, 4
    bltu a0, a1, 2b
3:
    // continue with startup...
```

That's it, I hope you learned a new trick, or at least recoiled from your screen in horror a couple of times.

