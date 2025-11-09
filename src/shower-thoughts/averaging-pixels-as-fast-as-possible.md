# Averaging Pixels as Fast as Possible

Suppose we have pixels stored in the RGB565 format, which I define as:

```
bit       | 15:11 | 10:5 | 4:0 |
component |   R   |   G  |  B  |
```

We could describe this bit layout with some constants like:

```c
#define R_BITS 0xf800
#define R_MSB  15
#define R_LSB  11

#define G_BITS 0x07e0
#define G_MSB  10
#define G_LSB  5

#define B_BITS 0x001f
#define B_MSB  4
#define B_LSB  0
```

How quickly can we calculate the average of two such pixels using 32-bit RISC-V instructions? Specifically, given two RGB565 scanline buffers of the same size (a few hundred pixels), what per-pixel throughput can we achieve? Since we're always averaging two integers, the fractional part of our result is always zero or one-half. We'll assume we always want to round this _down_, i.e. truncation.

## Performance Model

Assume a processor where ALU operations have a 1-cycle latency, and the processor issues one such instruction per cycle. This is typical for a small embedded processor like [Hazard3](https://github.com/wren6991/hazard3), which is where you might care about doing this sort of operation in software.

## Simple C Solution

It's a good idea to write a baseline implementation in a high-level language and see how you feel about the performance before you pull out all the stops with handcrafted assembly. We could solve our problem something like this:

```c
static inline uint16_t avg2_component(
        uint16_t p0, uint16_t p1, uint16_t mask, int lsb) {
    uint16_t c0 = (p0 & mask) >> lsb;
    uint16_t c1 = (p1 & mask) >> lsb;
    uint16_t avg = (c0 + c1) >> 1;
    return avg << lsb;
}

uint16_t avg2(uint16_t p0, uint16_t p1) {
    return
        avg2_component(p0, p1, R_BITS, R_LSB) |
        avg2_component(p0, p1, G_BITS, G_LSB) |
        avg2_component(p0, p1, B_BITS, B_LSB);
}
```

Our baseline algorithm is as follows:

* Isolate each individual component
* Add the matching components between the two pixels
* Halve the sum to calculate the mean of each component pair
* Pack the components back into one full pixel

[Godbolt](https://godbolt.org/z/PcY81rGaq) gives me:

```
avg2(unsigned short, unsigned short):
        andi    a5,a0,2016
        andi    a4,a1,2016
        srai    a4,a4,5
        srai    a5,a5,5
        srli    a3,a1,11
        add     a5,a5,a4
        srli    a4,a0,11
        add     a4,a4,a3
        andi    a1,a1,31
        srai    a5,a5,1
        andi    a0,a0,31
        srai    a4,a4,1
        slli    a4,a4,11
        add     a0,a0,a1
        slli    a5,a5,5
        or      a5,a5,a4
        srai    a0,a0,1
        or      a0,a5,a0
        ret
```

Under our performance model this is 18 cycles for the main body of the function.

## Parallelism over Components

Our processor can easily perform a full 16-bit addition in one cycle. This is very close to element-wise addition over our R, G and B components, except for the extra carries out of bits 4 and 10. Is there a way to sever those carries?

The idea comes from this classic identity for calculating the average of two register-sized integers:

```c
(a + b) >> 1 === ((a ^ b) >> 1) +  (a & b)
```

As an aside, this identity comes directly from a recursive definition of binary addition (this one does need one extra bit of integer width):

```c
 a + b       ===  (a ^ b)       + ((a & b) << 1)
```

The first identity can be derived by shifting both sides of the second identity right by one bit.

In the first identity, `a & b` represents the carry-out from each pair of bits in `a` and `b`. We actually want to leave this part alone and fiddle with the XOR term to prevent the carry into the MSB of each averaged component from interacting with the LSBs of higher components and generating further carries out.

```c
static const uint16_t CARRY_BREAK =
    (1u << R_MSB) | (1u << G_MSB) | (1u << B_MSB);

uint16_t avg2(uint16_t p0, uint16_t p1) {
    return (((p0 ^ p1) >> 1) & ~CARRY_BREAK) + (p0 & p1);
}
```

GCC -O3 gives:

```
avg2(unsigned short, unsigned short):
        xor     a5,a0,a1
        li      a4,32768
        addi    a4,a4,-1041
        srli    a5,a5,1
        and     a0,a0,a1
        and     a5,a5,a4
        add     a0,a5,a0
        slli    a0,a0,16
        srli    a0,a0,16
        ret
```

This is 7 ALU operations, plus 2 more instructions (`li a4; addi a4`) to generate a constant that is reused for each pixel and therefore has zero amortised cost over many pixels.

If we were writing this by hand, we would delete the final `slli; srli` (or `zext.h` if you have the Zbb extension); it's actually impossible to carry out into bit 16, since bit 15 of `((p0 ^ p1) >> 1)` is always clear. This brings us to 5 ALU ops, or a 72% reduction from baseline.

## Parallelism over Pixels

We are processing 16-bit pixels on a 32-bit processor. The astute reader will notice that 32 is twice 16. Can we leverage this for more throughput? I would not ask such a question if the answer were not "yes". Actually the code is almost exactly the same; we just need to take care of carries from the red component of pixel 0 into the blue component of pixel 1:

```c
static const uint32_t CARRY_BREAK = (
    (1u << R_MSB) | (1u << G_MSB) | (1u << B_MSB)
) * 0x10001u;

uint32_t avg2(uint32_t p0, uint32_t p1) {
    return (((p0 ^ p1) >> 1) & ~CARRY_BREAK) + (p0 & p1);
}
```

GCC -O3 gives:

```
avg2(unsigned int, unsigned int):
        xor     a5,a0,a1
        li      a4,2079293440
        addi    a4,a4,-1041
        srli    a5,a5,1
        and     a0,a0,a1
        and     a5,a5,a4
        add     a0,a5,a0
        ret
```

This is the same 5 ALU ops as the previous, but we're getting two pixels for our 5 cycles.

Asymptotically this gives us 2.5 cycles per pixel, plus the cost of loads and stores. With an unrolled loop we can avoid any load-use penalties, so that would just be another 2 cycles per 2 pixels (`lw + sw`) on a typical 32-bit embedded processor.


