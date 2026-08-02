The declared dependency is `irregex>=1.0.0,<2` instead of a bare `irregex`.

Unbounded, that resolves to `irregex==0.1.0` - the pre-rename placeholder on the index, which has no `irgx` module in it at all, so an install would succeed and then fail on the first import. The floor is 1.0.0 because that is where `irgx` starts existing; the ceiling is the same fact from the other side, since 1.0.0 is where the substrate froze the C ABI and the `irgx` surface and a 2.0 is free to move both. This is a face over an ABI, not a consumer of a loose utility.
