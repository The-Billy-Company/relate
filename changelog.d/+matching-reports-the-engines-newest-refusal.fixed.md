`--matching` handles `BoundUnsupported`, the fault `irregex` grew when its C ABI
learned bounded-window search. The switch over compile faults is deliberately
exhaustive - a new fault in the engine is meant to be a compile error here rather
than a mystery string in someone's terminal - so this is that mechanism working:
the engine added a member and this is the line that answers for it.

Nothing can produce it through `--matching`, which offers neither `-P` nor a
window bound. It is reported by name rather than asserted away, because a fault
that cannot happen is still cheaper to print than to trip over.
