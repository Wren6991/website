# A Love Letter to the Zbkb `pack` Instruction

The `pack` instruction from Zbkb is the best RISC-V instruction that nobody implements. On RV32, Zbkb contains the following bit manipulation instructions which are not present in Zbb:

* `zip`: mostly useless [^1]
* `unzip`: for when you executed a `zip` and you didn't mean to
* `brev8`: likely useful for something, people keep adding these to ISAs [^2]
* `pack`: pure magic
* `packh`: also pretty great

Expressed in Verilog, the operation of `pack` is:

```verilog
rd <= {rs2[15:0], rs1[15:0]};
```

Expressed in English, `pack` is the concatenation of the low halves of its two input registers. Its little brother `packh` is the concatenation of the two least-significant bytes into a zero-extended halfword.

Zbb dropped the `pack` and `packh` instructions late in the ratification process because [they were cut based on a SPECint benchmark with early compiler support](https://lists.riscv.org/g/tech-bitmanip-archive-2022/topic/81374235#msg438) and inertia was then in favour of leaving them out. A subset of `pack` was retained in Zbb as the `zext.h` pseudo-instruction (`rs2` is `zero`)[^3], but not the remaining encodings, and nothing for `packh` (as `zext.b` is a pseudo-instruction for `andi`).

The rationale for the full instructions' retention in Zbkb was likely to speed up loads from unaligned halfword and word fields on processors which lack native support for unaligned reads, since packed fields inside of octet streams are common in cryptographic workloads.

This post looks at three surprising uses of `pack` which have nothing to do with word or halfword data. Maybe it will become your favourite instruction too.

## Use 1: Unpacking

This excerpt from the [RP2350 bootrom](https://github.com/raspberrypi/armulet/blob/a95adb4e3a92ca6add831e6e742d824cd5b956f6/varmulet/varmulet_armv6m_core.S#L1142-L1157) unpacks the immediate operand from an Armv8-M Base `BL` (T1) or `B.W` (T4) instruction:

```c
vexecute32_bw:
                                          // r_inst[12:0] = 1  0  S  imm10
    addi        r_tmp2, r_inst, -1024     // r_tmp2[12:0] = S !S !S  imm10
    slli        r_tmp0, r_work2, 5        // concatenate imm11 to end (plus 5 incidental zeroes)
    pack        r_tmp2, r_tmp0, r_tmp2    // (it's called pack but I use it to unpack things???)
    slli        r_tmp2, r_tmp2, 3         // Sign-extend and scale by 2 overall (sll 5 + 3 - 7)
    srai        r_tmp2, r_tmp2, 7         // {{8{S}}, !S, !S, imm10, imm11, 1'b0}

    bexti       r_tmp0, r_work2, 13       // J1
    bexti       r_tmp1, r_work2, 11       // J2
    sh1add      r_tmp0, r_tmp0, r_tmp1    // {J1, J2}
    slli        r_tmp0, r_tmp0, 22

    xor         r_tmp0, r_tmp0, r_tmp2    // Mix the pasta and the sauce
    add         r_pc, r_pc, r_tmp0
    next_instruction
```

The encoding of the `BL` instruction was designed using the classic party game _pin the tail on the donkey_.[^4] It seems to break the bitfield renderer on [Arm's online docs](https://developer.arm.com/documentation/ddi0403/d/Application-Level-Architecture/Instruction-Details/Alphabetical-list-of-ARMv7-M-Thumb-instructions/BL) so here is my bitfield diagram:

```
First halfword (r_inst):

  15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
 +---+---+---+---+---+---+---------------------------------------+
 | 1 | 1 | 1 | 1 | 0 | S |              imm10[9:0]               |
 +---+---+---+---+---+---+---------------------------------------+
  \________________/
      op = 11110

Second halfword (r_work2):

  15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
 +---+---+---+---+---+-------------------------------------------+
 | 1 | 1 |J1 | 1 |J2 |              imm11[10:0]                  |
 +---+---+---+---+---+-------------------------------------------+
```

The offset is computed as:

```
  I1    = !(J1 ^ S)
  I2    = !(J2 ^ S)
  imm32 = SignExtend( S : I1 : I2 : imm10 : imm11 : '0' , 32 )
                bit: 24   23   22   21:12   11:1     0
```

Here `pack` is used for concatenation of unpacked bits. There are very few instructions in RISC-V that can take bits from the same locations in two different source registers and combine them without overlap: the other ones I'm aware of are the `sh*add` family, which also make an appearance in this excerpt. It looks like the P extension might add more.

`pack` is profitable because it replaces the usual `s*li` + `or` combinations, as well as masking the bits above `imm11` in `r_work2` that would otherwise contaminate the result. These bits are masked because they end up above the concatenation boundary. One other detail that makes it particularly applicable here is that the result is about to be shifted _anyway_ so the fact that the concatenation is at a 16-bit boundary doesn't really matter: the first comment describes the pre-shift as "5 incidental zeroes" because the 5 is just subtracted from the shift distance of the subsequent shift-by-8. This may seem situational but it's actually quite likely when reconstituting bitfields that the next thing you do after combining some bits is to shift them.

## Use 2: Widening Multiplication

$32 \times 32 \rightarrow 64$-bit multiplication using only the $32 \times 32 \rightarrow 32$-bit `mul` instruction is useful because high-half multiplies are significantly slower than the low `mul` on some RISC-V implementations. The instructions are mandatory if you have M or Zmmul, but useful levels of performance are not.[^5] Computing the widening multiply requires a carry into bits `0` and `16` of the high word. You can accomplish this by adding the low carry, then shifting the high carry by 16, then adding the high carry. You could also just `pack` the two carries and add them in one go:

```c
    // Values to be multiplied are in a0 and a1.
    srli a2, a0, 16
    srli a3, a1, 16
    zext.h a0, a0
    zext.h a1, a1
    mul a4, a2, a3  // A_h * B_h
    mul a5, a2, a1  // A_h * B_l
    mul a2, a0, a3  // A_l * B_h
    mul a0, a0, a1  // A_l * B_l
    // Sum the crossed terms, save carry-in for hi[16]
    add a5, a2, a5
    sltu t0, a5, a2
    // Add crossed terms to low word, save carry-in for hi[0]
    slli a2, a5, 16
    add a0, a0, a2
    sltu a3, a0, a2
    // Pack carries with correct significance
    pack a3, a3, t0
    // hi: A_h * B_h + (crossed terms >> 16) + ci0 + (ci1 << 16)
    srli a5, a5, 16
    add a1, a4, a5
    add a1, a1, a3
    // Product is in {a1, a0}
```

## Use 3: Memset

The second argument to `memset` is a byte value that must be replicated up to register width in order to use the widest possible store instruction. This can be accomplished [like this](https://github.com/raspberrypi/pico-bootrom-rp2350/blob/c6cdb1711f32c3e34faaebd58618a6d096dbd52e/src/main/riscv/riscv_misc.S#L129-L162):

```c
    packh a1, a1, a1
    pack a1, a1, a1
```

This can also be accomplished in one operation with `xperm8 rd, rs1, zero` but the Zbkx instructions have higher implementation complexity than `pack`/`packh`.

The best you can do without Zbkb or Zbkx is three instructions:

```c
    li t0, 0x01010101 // expands to lui + addi
    mul a1, a1, t0
```

This also needs to _assume_ that `a1` is zero outside of the lower eight bits. The `packh` + `pack` version and the `xperm8` version are independent of bits `31:8`.

`memset` is one of the most-frequently-called C library functions, often with quite a small length parameter for initialising short arrays or structs on the stack. These savings on the O(1) part of `memset` add up.

On RV64 a similar trick applies to generating repeating bit patterns useful for SIMD-within-a-register tricks. This tends not to be useful on RV32, since `lui` + `addi` generates any 32-bit value, but there are sometimes minor code size savings.

## Use 4: Packing

I know, I promised three uses for `pack` at the start, but it's just that good. Also this one is `packh`, so it doesn't count. This is from a [single-precision floating-point add](https://github.com/raspberrypi/pico-sdk/blob/a1438dff1d38bd9c65dbd693f0e5db4b9ae91779/src/rp2_common/pico_float/float_single_hazard3.S#L235-L241) routine. `a2` contains the exponent, `a6` contains the sign bit (smeared across the entire register) and `a4` contains the significand, with an implicit one in bit `31` that needs to be cleared.

```c
    // Pack it and ship it
    packh a2, a2, a6
    slli a2, a2, 23
    slli a4, a4, 1
    srli a4, a4, 9
    add a0, a4, a2
    ret
```

The result is the concatenation `sign : exponent : significand` where the fields are 1, 8 and 23 bits in size respectively.

## What Could Have Been

I think it's a shame that `pack` and `packh` didn't make it into the standard B extension (made up of Zba, Zbb and Zbs), and consequently not into RVA23. When it comes to Hazard3 I'm not too bothered because I can choose what ISA variants I ship, and you can bet they will always include Zbkb. Overall though I think the RISC-V software landscape is made slightly poorer by portable software not being able to assume the presence of these versatile and inexpensive instructions.

The decision to drop `pack` and `packh` seems to me somewhat arbitrary, and likely a symptom of a long and gruelling ratification process and the pressure to ship the extensions. Several people spoke up in their favour but it wasn't enough to keep them on the list.


[^1]: One use for `zip` is Morton-order access e.g. to swizzled textures, but _iterating_ in Morton order is already accomplished efficiently with masked addition as described [here](https://github.com/rcoscali/ftke/blob/master/ogles/doc/fatmap2.txt#L701) or [here](https://fgiesen.wordpress.com/2011/01/17/texture-tiling-and-swizzling/).

[^2]: The somewhat equivalent `RBIT` (synthesises as `rev8` + `brev8`) is useful on Armv7-M and Armv8-M Main to synthesise the missing `CTZ` as `RBIT` + `CLZ`. They're also useful sometimes in CRC calculations. The most important use of bit reverse instructions is of course the efficient emulation of bit reverse instructions from other architectures.

[^3]: It's actually a little different on RV64, but for brevity I'm just discussing the specifics of RV32.

[^4]: The `BL` instruction (or the _fujoshi_ instruction) was originally specified as a separate 16-bit prefix and 16-bit suffix, with a range of 4 MB. Armv5T added a _different_ suffix that could go with the prefix (`BLX` immediate). Armv6T2 stuffed in more bits to expand the range to 16 MB even though the new bits were previously constant-1 and they needed to stay backwards-compatible, hence the weird XNOR encoding. Finally the T32 encoding formally defined `BL` as a 32-bit instruction.

[^5]: For example, Hazard3 with the configuration `MUL_FAST` = `1`, `MULH_FAST` = `0` has a single-cycle `mul`, but high-half multiplies have the same cycle count as division. This is usually a well-balanced configuration because the full widening multiplier is a lot of gates, and `mul` is executed far more frequently than `mulh`/`mulhu`/`mulhsu`.

