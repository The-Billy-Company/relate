The Rust integration suite could report a clean pass having run nothing. Each of
its five tests opened by probing for a `relate` binary and returning early when
it found none — and Rust's stable harness has no conditional skip, so an early
return is indistinguishable from a completed test. With no binary reachable the
suite printed `5 passed` in 0.00s, which is the one result CI must never be able
to produce quietly: a green tick over an untested seam.

The probe is now a precondition that fails instead of returning, naming the
binary it looked for, what went wrong, and the two ways to fix it (`zig build`,
or point `RELATE_BIN` at one). This is the line the exact face's suite already
holds — "do not Skip (test-bandaid)" — and integration tests whose stated
purpose is to run the real thing are exactly where it belongs. With the binary
present the five still pass, in 0.02s of actual work rather than 0.00s of none.
