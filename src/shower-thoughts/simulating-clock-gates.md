# Simulating Clock Gates

I recently debugged a simulation race caused by a vendor model for a clock gate cell which introduces a non-blocking assignment delay between its input and its output clock pins. I can't name the foundry but you have heard of them. The root cause is that Verilog's IEEE Std 1364 is a spring-loaded box of razor blades that can be used for hardware design if you hold it _just right_, but it's still frustrating to keep seeing the same bugs.

There are two golden rules for simulating designs with synchronous paths between a parent and child clock:

* Do not introduce non-blocking assignment delays on the child clock.

    * Otherwise there is non-deterministic ordering between NBA evaluation for the child clock and NBA assignment for the parent clock.

* Do not derive the child clock from multiple variables which can toggle in the same trip through the non-blocking assignment stage of the event loop.

    * Otherwise you may introduce spurious transitions on the output which collapse within one NBA update loop but can still clock downstream logic; these transitions are also non-deterministic based on the order the assignments are scheduled.

This is a correct Verilog 2005 behavioural model for a low-type clock gate:

```verilog
module ckgate_low (
    input  wire clk_in,
    input  wire enable,
    output wire clk_out
);

    reg enable_q;

    // Transparent latch. Yes, non-blocking!
    always @ (*) if (!clk_in) enable_q <= enable;

    // Gate clock using latched enable.
    assign clk_out = clk_in && enable_q;

endmodule
```

There are a lot of variations on this module. Some are obviously broken and some are subtly broken. This particular version closely matches the AND-and-latch type of clock gate cell you see often in ASIC cell libraries.

Sometimes you'll see a reset on the latch, but this is not strictly necessary if `clk_in` is known to be low at reset. Sometimes you'll see an additional `enable` input for forcing clocks to run during test modes: you can model this with a different expression on the right-hand-side of the `enable_q` assignment.

There is an important _non-rule_ for modelling clock gates:

* Never use a non-blocking assignment in a combinatorial process (?)

This is a common rule of thumb for modelling synchronous circuits which is completely wrong in this context. Replacing the non-blocking assignment in the latch with a blocking assignment creates a glitch because the assignment is not deferred, so happens before the continuous assign of `clk_out`.

In SystemVerilog it's better to use an `always_latch` for the `enable_q` update to avoid warnings about a non-explicit inferred latch. However you should still use a non-blocking assignment to get the correct ordering with respect to the continuous assignment of `clk_out`.

## My Coworker Said Latches Are Evil

Yes, I've heard this one. The purpose of the latch is twofold:

* To ensure `enable_q` does not change in parts of the cycle where the AND is sensitive to it (`clk_in` is high); the logic that generates `enable` may have static hazards, and the clock output must not see those transitions.

* To ensure `enable` makes it to the AND gate strictly _before_ the next rising edge of `clk_in`; this is why it's a transparent latch rather than a posedge flop.

The timing paths are:

* Setup timing: the path _through_ the latch D and Q pins (it's transparent!) into the AND gate is timed before `clk_in` into the AND gate.

* Hold timing: the path _into_ the latch D pin is timed after `clk_in` into the latch E pin.

The latch is necessary to provide a full cycle of propagation time for the clock enable. It is safe if correctly timed, just like any other element of a synchronous circuit. In practice the AND and latch are integrated into one cell, and the paths I mentioned above just look like normal setup and hold paths.

## What about Just an OR Gate?

You sometimes see a clock gate modelled (or synthesised) like this:

```verilog

assign clk_out = clk_in || !enable;

```

When you see this it usually means one of two things:

* Whoever wrote this had no idea what they were doing, and you just booked a one-way ticket to glitch city.

* This is a valid circuit, but the setup on `enable` is a half-cycle path up to the `negedge` of `clk_in` at the OR gate.

Any `enable` transitions while `clk_in` is low propagate immediately to `clk_out`, so `enable` must be stable before this.

Clock enables are often high-fanout nets so a half-cycle path can cause timing issues. On ASIC I mostly see the AND-and-latch type described earlier, but some FPGA tools are able to infer technology-specific clock gating from this simple combinatorial circuit, so it has its place.
