# Reversing Bits on Armv6-M

Armv6-M lacks an `rbit` instruction, unlike Armv7-M or Armv8-M. If you do find yourself wanting to reverse bits on this architecture, in defiance of the ancestors' decision, here is one neat way of doing it:

```
__bitrev32:
	movs r2, #32
1:
	lsrs r0, #1
	adcs r1, r1
	subs r2, #1
	bne 1b
	movs r0, r1
	bx lr
```

Most of this function is just setting up a loop that runs for 32 iterations. The real work happens in these two instructions:

```
	lsrs r0, #1
	adcs r1, r1
```

The `lsrs` (logical shift-right, setting flags) shifts one bit off the end of `r0` and into the carry flag. The `adcs` (add with carry-in, setting flags) does two operations:

* Add `r1` to itself, thus shifting left by one
* Add the carry flag (shifted from LSB of `r0`) to LSB of `r1`; this is initially clear because `r1` + `r1` is an even number, so the effect is to shift _into_ `r1`

So the entire function can be summed up as: "32 times, shift a bit right out of `r0` and shift it left into `r1`, then return `r1`." This is a bit-reverse operation.

One surprising thing about the above function is it doesn't have to initialise `r1`, because shifting the register left 32 times completely erases the original value.

## A Better Way

It is a well-known fact that the best way to get an answer on the internet is to post something incorrect and wait for someone to correct you. A corollary is that to determine the best way to do something you should post a flawed approach and wait for someone to best it. This code is due to [TcRe8r on Mastodon](https://mastodon.social/@TcRe8r/115514218853835253):

```
__bitrev32:
    movs r1, #1  
1:  
    lsrs r0, #1  
    adcs r1, r1  
    bcc 1b  
    mov r0, r1  
    bx lr
```

Initialising `r1` to one, and then doubling it 32 times via `adcs`, sets the carry flag. This avoids having to maintain a separate loop counter, saving one subtraction per loop as well as one register clobber.
