The Python binding has an import contract: `bindings/python/binding.zone`,
governing `relate-search` the way `charter.zone` governs the Zig side.

The package is flat on purpose - `corpus` holds the scope, the timeout, and the
run helper that `kinship`, `retrieval`, `sweep`, and `lifecycle` are each a
specialization of - so the contract says one zone and means it, rather than
inventing tiers between peers. What it does pin is the reach outside: `irgx`
underneath, `gist` in the tests only, as the independent oracle a
compression-based verdict should be checked against.

Needs `zoning` 1.3.1, which is where the `python` dialect and root-anchored
contracts both arrive.
