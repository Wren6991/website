# Testing for Powers of Two

There is a classic trick for testing if a number is a power of two (or zero), which you may recognise from places like Hacker's Delight:

```
(x & (x - 1)) == 0
```

The intuition here is:

* Powers of two have exactly one set bit (in binary representation)
* `x & (x - 1)` clears the least set bit (aka the rightmost one)
* If, after clearing one bit, you have no bits set (i.e. zero) then you initially had either 0 or 1 bits set

To understand why `x & (x - 1)` clears the least (i.e rightmost) set bit, you need to reframe how you think about decrementing a binary integer:

* The trailing zeroes (zeroes to the right of the rightmost one) are set
* The least set bit is cleared

For example:

```
  0101010000
-          1
= 0101001111
```

ANDing this with the original value has no effect on the trailing zeroes, as they are already clear. It clears the rightmost one, as `b & 0` is `0` for all `b`. It has no effect on the bits to the left of the rightmost one.

This is all leading up to another power-of-two test:

```
(x & -x) == x
```

The `x & -x` is a really useful expression on its own: it clears all bits _except for_ the rightmost one. RTL engineers will recognise this as a priority selector, but here it's a function which is a no-op on powers of two (and zero), but modifies other inputs.

To see why `x & -x` clears all bits except for the rightmost one, you need to think about negation in a particular way. First break it down into a bitwise complement followed by an increment, using the two's complement identity:

```
-x === ~x + 1
```

Increment can be rephrased as: clear the trailing ones, and set the rightmost zero. For example:

```
  1010100001111 
+             1
= 1010100010000
```

Initially the bit string ended with a zero followed by four ones. It now ends with a one followed by four zeroes; the last five bits are _inverted_. Since the original `x` in our two's complement identity is already inverted once, we are actually inverting these trailing bits a second time, restoring their original value. Furthermore the rightmost zero in our example above was actually the rightmost one in the original `x`, and the trailing ones were originally trailing zeroes. So, working through from an initial `x` value:

```
 x     = 0101011110000
~x     = 1010100001111
-x     = 1010100010000
```
This brings us to a neat way of thinking of two's complement negation:

>  **Negation is an inversion of all bits to the left of the rightmost one.**

Tying this back to our power-of-two test: if we negate an integer, all bits to the left of the rightmost one are inverted. ANDing these bits with their original values clears them. Therefore `x & -x` returns the original `x` with _only_ its least set bit set, and all other bits cleared. Continuing the example from above:

```
 x     = 0101011110000
-x     = 1010100010000
x & -x = 0000000010000
```


This is an identity map if and only if the number of set bits is 0 or 1, which is true only for powers of two and zero.

What are the uses for this? As far as I can tell, none: it should result in similar hardware to the original expression, and both expressions can be computed and branched upon in 3 RISC-V instructions, with the original formula having slightly better compressibility. Still, it's interesting to think about.
