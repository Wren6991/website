# Mark's Magic Multiply

This post is about a topic very near and dear to my heart. That's right: _single-precision floating-point multiplication on embedded processors_. I'll start with some background on why I've been so invested in this topic recently, walk through the implementations I've come up with on my own, and end by dissecting an absolutely ridiculous trick by Mark Owen for floating point multiplication on 32-bit embedded cores, which was the original inspiration for this post.

> **⚠️ This post contains floating point.** Floating point is known to the State of California to cause confusion and a fear response in mammalian bipeds. The standard recommendation is [What Every Computer Scientist Should Know About Floating-Point Arithmetic ](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html). The actual [IEEE 754-2008 standard](https://www.google.com/search?q=ieee+754+2008+pdf) is also uncharacteristically concise and readable, provided you ignore the fan fiction about radix != 2. For a more tactile experience try poking ones and zeroes into [IEEE 754 Calculator](https://weitz.de/ieee/) (start with binary16).

## Not Hard, Not Soft

Lately I've been working on a custom %!riscv extension called [Xh3sfx](https://wren.wtf/hazard3/doc/dev/#extension-xh3sfx-section) for accelerating soft floating-point routines. This is a halfway house between having an FPU and not having an FPU, which I feel is an under-explored space. You could call it _firm floating point_.

When you compile a C program using `float` variables for a target that lacks floating-point hardware support, the compiler inserts calls to a runtime library like [libgcc](https://gcc.gnu.org/onlinedocs/gccint/Soft-float-library-routines.html) or [compiler-rt](https://github.com/llvm/llvm-project/blob/main/compiler-rt/lib/builtins/README.txt) to perform the requested operations. This is sometimes called _floating point emulation_ because it fills the role of a hardware FPU, but really it's just one approach to implementing the floating-point operations specified in IEEE 754.

Although Xh3sfx is a custom extension, I'm not signing up to maintain and distribute a forked compiler. It's easier to just replace the compiler runtime routines with accelerated versions. The new routines use a handful of specialised ALU operations to handle the gritty and ugly parts of floating point formats, mixed in with regular integer instructions for the actual computation. The runtime libraries have a mostly documented and stable API surface. Adding support to your program just requires linking the acceleration library or adding its source files to your build, which is a reasonable approach for embedded firmware.

For a nominal fee of a few hundred gates, Xh3sfx gives you single-precision addition in 14 cycles and multiplication in 16 cycles, ignoring function call overhead. (It can do other stuff too, these are just examples.) Qualitatively this turns floating point from "oh god why is this so slow" to something that Just Works™ in general applications code and light audio DSP. I originally posted about it on Mastodon [here](https://types.pl/@wren6991/116302915668678750). You can read about the instructions [here](https://wren.wtf/hazard3/doc/dev/#extension-xh3sfx-section) and see some library routines [here](https://github.com/Wren6991/Hazard3/blob/b9ddef48bb21ba67a50958ba9d9bc4a802c4ebae/test/sim/common/xh3sfx_float_lib.S).

## Multiplying with Xh3sfx

The default single-precision multiply implementation in the Xh3sfx library has the following steps:

* Unpack the exponents and significands from the two floating-point inputs.
* Calculate the exact significand product with a $32 \times 32 \rightarrow 64$-bit multiply (`mul; mulh`).
* Squash the product back into a 32-bit register in a way that preserves its rounding direction.
* Normalise the product.
* Pack the product with the sum of the original exponents to yield the final floating point result.

Concretely it looks like this:

```c
__mulsf3:
	// Unpack exponents
	h3.bextmi a2, a0, 23, 8
	h3.bextmi a3, a1, 23, 8
	// Special cases: at least one input is zero/subnormal/NaN/inf
	h3.fcheck2e.s t0, a2, a3
	bnez t0, __mulsf_special_exponent
	// Unpack single-precision significands as Q3.29
	h3.funpackq3.s a4, a0
	h3.funpackq3.s a5, a1
	// Multiply Q3.29 x Q3.29 -> Q6.58
	mul a1, a4, a5
	mulh a4, a4, a5
	// Gather sticky bits from low fraction; a4 now effectively Q6.26
	snez a1, a1
	or a4, a4, a1
	// Shift up to Q3: this shift is exact as it's always to-left
	h3.feadjq3 a5, a4
	h3.ssra a4, a4, a5
	// Calculate new exponent;
	// -127 is for redundant bias, +3 is for Q6 -> Q3 offset
	add a2, a2, a3
	add a2, a2, a5
	addi a2, a2, -127 + 3
	// Pack single-precision with rounding
	h3.fpackrq3.s a0, a4, a2
	ret
```

Instructions prefixed with `h3.*` are from Hazard3 custom extensions, specifically [Xh3bextm](https://wren.wtf/hazard3/doc/#extension-xh3bextm-section) for `h3.bextmi` and [Xh3sfx](https://wren.wtf/hazard3/doc/dev/#extension-xh3sfx-section) for the rest. ALU ops and non-taken forward branches are one cycle each, so this comes out to 16 cycles (ignoring the function call overhead).

This implementation is optimal assuming `mul` and `mulh` are equally fast, and assuming you require correctly-rounded results for all inputs. It's possible to save two cycles if you can tolerate ~0.5 ulp of error; this is left as an exercise for the reader (I always wanted to say that).

## Schoolbook Multiplication

Hazard3 has three [hardware configurations](https://wren.wtf/hazard3/doc/#_multiplydivide) for multiplication:

1. Minimal: All divide and multiply instructions execute on a sequential multiply/divide circuit, usually configured for either 1 or 2 bits per cycle, plus a couple of extra cycles for sign correction.
2. Intermediate: $32 \times 32 \rightarrow 32$-bit `mul` executes on a dedicated fast multiplier; the remaining multiplies `mulh`/`mulhu`/`mulhsu` still execute on the sequential multiply/divide circuit.
3. Full: All multiplies execute on a dedicated fast $32 \times 32 \rightarrow 64$-bit multiplier. Divides still execute on the sequential circuit.

These options are arranged in ascending order of both performance and area cost. The full $32 \times 32 \rightarrow 64$-bit multiply is the option that was taped out on RP2350. For a minimal implementation with just the sequential multiply/divide, the `mul; mulh` implementation discussed earlier is again optimal. Option 2 is still interesting because it's a well-balanced design: `mul` is overwhelmingly the most commonly executed instruction in the M extension.

My first attempt at optimising for this configuration was to break the $32 \times 32 \rightarrow 64$-bit multiplication into four $16 \times 16 \rightarrow 32$-bit multiplications, which each execute in a single cycle using the `mul` instruction.

```c
__mulsf3:
	// Unpack and check exponents
	h3.bextmi a2, a0, 23, 8
	h3.bextmi a3, a1, 23, 8
	h3.fcheck2e.s t0, a2, a3
	bnez t0, __mulsf_special_exponent
	// Unpack significands as unsigned to simplify multiplication
	h3.funpacku3.s a4, a0
	h3.funpacku3.s a5, a1
	// Calculate sign and exponent; free up a2/a3
	xor a0, a0, a1
	add a1, a3, a2
	addi a1, a1, -127 + 3
	// Multiply U3.29 x U3.29 -> U6.58. (32 x 32 -> 64)
	srli a2, a4, 16
	srli a3, a5, 16
	zext.h a4, a4
	zext.h a5, a5
	mul t0, a2, a3  // A_h * B_h
	mul t1, a2, a5  // A_h * B_l
	mul a2, a4, a3  // A_l * B_h
	mul a4, a4, a5  // A_l * B_l
	// Sum the crossed terms, save carry-in for hi[16]
	add t1, a2, t1
	sltu t2, t1, a2
	// Add crossed terms to low word, save carry-in for hi[0]
	slli a2, t1, 16
	add a4, a4, a2
	sltu a3, a4, a2
	// Pack carries with correct significance
	pack a3, a3, t2
	// High word: A_h * B_h + (crossed terms >> 16) + ci0 + (ci1 << 16)
	srli t1, t1, 16
	add a5, t0, t1
	add a5, a5, a3
	// Final product complete: U6.58 in a5:a4. Collect low sticky bits.
	snez a4, a4
	or a5, a5, a4
	// Renormalise to Q3
	h3.feadju3 a4, a5
	h3.ssra a5, a5, a4
	add a1, a1, a4
	// Apply sign before packing. Only upper U3.29 is relevant.
	h3.xorsign a5, a0, a5
	h3.fpackrq3.s a0, a5, a1
	ret
```

This is the familiar binomial product:

$$
(x_1 + x_0)(y_1 + y_0) = x_1 y_1 + x_1 y_0 + x_0 y_1 + x_0 y_0
$$

If you set $A = a_1 \times 2^16 + a_0$, where $a_1$ and $a_0$ are the two 16-bit halves of 32-bit $A$, then the product $AB$ expands into a sum of four $16 \times 16 \rightarrow 32$-bit multiplies with some additional factors of $2^n$ (i.e. shifts).

Most of the time is spent on routing bits to the right place, not on multiplication. Propagating the carries is quite involved, even with some help from the most underrated %!riscv instruction, `pack`. The body of this function executes in 33 cycles. This is still respectable but it's just over twice the execution time of the `mul; mulh` version.

## Mark's Magic Multiply

It's difficult to improve on the above code. One problem you will encounter if you try is the literature is obsessed with reducing the number of multiplies, but in a short pipeline `mul` has the same cost as any other integer ALU operation. For example [Karatsuba multiplication](https://en.wikipedia.org/wiki/Karatsuba_algorithm) is a neat identity that reduces the number of partial product multiplies from four to three. It's kind of like [Strassen's algorithm](https://en.wikipedia.org/wiki/Strassen_algorithm) but for scalars. Unfortunately it brings some setup and teardown costs, as well as a requirement to handle 33-bit intermediates. I haven't done the working but the seat of my pants says it's going to be slower. It's probably more useful at higher ratios of product size to multiplier size, so you get some compounded savings from the recursion.

I was happy with my implementation until Mark Owen emailed me out of the blue with [this trick](https://github.com/raspberrypi/pico-bootrom-rp2040/blob/ef22cd8ede5bc007f81d7f2416b48db90f313434/bootrom/mufplib.S#L890-L935) (%!armv6m):

```
 lsls r0,#8     @ x mantissa
 lsls r1,#8       @ y mantissa
 lsrs r0,#9
 lsrs r1,#9

 adds r2,r0,r1    @ for later
 mov r12,r2
 lsrs r2,r0,#7    @ x[22..7] Q16
 lsrs r3,r1,#7    @ y[22..7] Q16
 muls r2,r2,r3    @ result [45..14] Q32: never an overestimate and worst case error is 2*(2^7-1)*(2^23-2^7)+(2^7-1)^2 = 2130690049 < 2^31
 muls r0,r0,r1    @ result [31..0] Q46
 lsrs r2,#18      @ result [45..32] Q14
 bcc 1f
 cmp r0,#0
 bmi 1f
 adds r2,#1       @ fix error in r2
1:
 lsls r3,r0,#9    @ bits off bottom of result
 lsrs r0,#23      @ Q23
 lsls r2,#9
 adds r0,r2       @ cut'n'shut
 add r0,r12       @ implied 1*(x+y) to compensate for no insertion of implied 1s
@ result-1 in r3:r0 Q23+32, i.e., in range [0,3)
```

Mark is the author of the RP2040 ROM float library, and his emails are always hard-wrapped to 80 characters. This function returns correctly-rounded single-precision multiplies with just _two_ $32 \times 32 \rightarrow 32$-bit partial products. It also does it with a lot less bit twiddling and general waffling about than my schoolbook multiplication, even with a much more limited instruction set.

The core trick is to compute a $23 \times 23 \rightarrow 46$-bit product using two multiplies. This trick doesn't work for 24-bit inputs, so he leaves out the implicit one, multiplies just the 23-bit fractional parts, then compensates later for the missing one. Starting to work through:

```
 muls r0,r0,r1    @ result [31..0] Q46
```

The lower multiply directly gives us the lower 32 bits of the result. This part is exact.

```
 lsrs r2,r0,#7    @ x[22..7] Q16
 lsrs r3,r1,#7    @ y[22..7] Q16
 muls r2,r2,r3    @ result [45..14] Q32: never an overestimate and worst case error is 2*(2^7-1)*(2^23-2^7)+(2^7-1)^2 = 2130690049 < 2^31
```

The upper multiply gives bits `45:14` of a number that is close to our result. The precise result for these bits would be `(x * y) >> 14` (without intermediate truncation); we've instead calculated `(x >> 7) * (y >> 7)`, which is close but misses the contributions from the 7 LSBs on each side.

If we could just glue bits `45:32` from the high multiply onto bits `31:0` from the low multiply, we would have our full 46-bit result. Unfortunately it's just an approximate result at this point (let's call it `approx[45:14]`). Mark calculates the error $e$ is bounded $-2^31 < e \leq 0$ (with the lower bound rounded down to a power of two). This bound eliminates all but two possibilities:

* Result bits `45:31` are already correct.
* Result bits `43:31` are wrong, but are corrected by adding $2^31$.

This correction doesn't fix result bits `30:14`, but that's fine: we have those already from the low multiply. The correction logic is here:

```
 lsrs r2,#18      @ result [45..32] Q14
 bcc 1f
 cmp r0,#0
 bmi 1f
 adds r2,#1       @ fix error in r2
1:
```

In English, the above code says: "Increment `approx[32]` if `approx[31]` is set, AND `exact[31]` is clear. Discard `approx[31:14]`." This is equivalent to the carry-out from adding `approx[31] ^ exact[31]` into `approx[31]`, which is exactly the necessary correction. The 14 LSBs of `r2` now contain bits `45:32` of the exact result, so we have our full 46-bit product with two multiplies. The rest of the code shifts and concatenates these bits in a way that is convenient for rounding later, and partially compensates for the missing implicit 1.

When I asked Mark about it he proferred this explanation, which I think is elegant but not quite the right shape for my brain:

> > So the error bound you calculated
> > means that, if r[31] differs between the high and low mul, then the correct
> > fix is to increment the high mul at r[31]. Your code applies an increment to
> > r[32] only in the case where r[31] is set in the high mul and clear in the
> > low mul, which would yield a carry into r[32]. Your code ignores the
> > opposite case of r[31] being clear in the high mul and set in the low mul,
> > because this yields no carry into r[32]. Am I on the right track?
> 
> Yes. The way I think of it is that the bottom 32 bits are guaranteed all
> correct. The worst case error in taking the top 16 bits of the product
> of the top halves is 2, so if you could arrange to overlap those two
> results by two bits instead then you are guaranteed at most one carry
> into the top part and you can fix everything up.

## Making My Multiply More Magical

It comes out quite different on RISC-V, but it turns out this trick is both usable and profitable.

```c
__mulsf3:
	h3.bextmi a2, a0, 23, 8
	h3.bextmi a3, a1, 23, 8
	h3.fcheck2e.s t0, a2, a3
	bnez t0, __mulsf_special_exponent
	// This uses a variant of Mark Owen's trick for calculating a 23 x 23 ->
	// 46-bit product with two 32-bit multiplies.
	li t2, -1 << 23
	andn a4, a0, t2           // x - 1, U0.23
	andn a5, a1, t2           // y - 1, U0.23
	bseti t2, a4, 23
	add t2, t2, a5            // x + y - 1, U2.23 (useful later)
	xor a0, a0, a1            // sign
	add a1, a3, a2            // a2/a3 now free
	addi a1, a1, -127 + 3     // exponent
	mul a2, a4, a5            // exact[31:0]
	srli a4, a4, 7
	srli a5, a5, 7
	mul a4, a4, a5            // approx[45:14]
	// Error on approx[45:0] is slightly better than -2^31 < err <= 0.
	// Only two possibilities:
	//
	// * approx[45:31] is equal to exact[45:31]
	//
	// * approx[31] differs from exact[31]; adding 2^31 corrects bits 45:31
	//
	// Carry into approx[32] occurs when approx[31] is set and exact[31] is
	// clear. So, adding !exact[31] to approx[31] corrects bits 45:32 (only).
	srli a4, a4, 17
	bltz a2, 1f
	addi a4, a4, 1
1:
	srli a4, a4, 1
	// Now: exact[45:32] in a4, exact[31:0] in a2. Pack U6.26 with sticky LSB.
	slli a4, a4, 12
	li a5, 20
	h3.ssrlsticky a2, a2, a5
	or a4, a4, a2
	// Just got:     p = (x - 2^23)(y - 2^23)
	//                 = xy - (x + y) * 2^23 + 2^46
	// Already had:  s = x + y - 2^23
	//
	// Want:        xy = p + (s + 2^23) * 2^23 - 2^46
	//                 = p + s * 2^23
	sh3add a4, t2, a4
	// Normalise to U3.29
	h3.feadju3 a5, a4
	h3.ssrlsticky a4, a4, a5
	add a1, a1, a5
	// Apply sign before packing.
	h3.xorsign a4, a0, a4
	h3.fpackrq3.s a0, a4, a1
	ret
```

There are some differences. One is that the correction of the approximate product is slightly cheekier, and only corrects up from bit 32 instead of bit 31. The implicit one wrangling is also completely different.

This saves 3 cycles, for a 30-cycle `fmul`. If you hadn't noticed, all of these functions fit in the RVE registers (`x0`-`x15`), so this would run on a core in the Cortex-M0+ weight class.

I think this technique can be generalised to using $32 \times 32 \rightarrow 64$-bit multiplies for the  $52 \times 52 \rightarrow 104$-bit inner product in a double-precision multiply, but I haven't proven it.

