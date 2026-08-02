"Compression-as-search" is the answer, not the question. Nobody arrives at a
package index having already decided that compression is how they want to find
duplicated code - they arrive typing "duplicate code", "clone detection", "code
similarity", "near-duplicate files". The metadata was written entirely in the
first vocabulary and none of the second, and "kinship", "retrieval", and "sweep"
are this package's internal nouns on top of that.

So the summary now leads with code similarity search and says what comes back
(near-duplicate files, clone families, where a snippet came from), with the
mechanism kept as the differentiator it is: no embeddings, no model, no vector
database. The keywords cover the job, the tools somebody is already using when
they come looking (jscpd, cpd, simian, moss), and the literature terms for the
smaller audience that arrives knowing them (lzjd, ncd, minhash, ziv-merhav).
The README's h1 says it too, with one line above the origin story so the first
screen is not all etymology.

The Python binding's README was thirteen lines of contributor notes pointing at
a file path, which would have been the entire PyPI landing page. It is a real
one now: both kinship questions with worked examples, the retrieval and
provenance verbs, what `matching` narrowing is for, what the atlas buys, and the
grade bands that keep a background answer from reading as a find. Every example
is checked against the current signatures - `Packed.coverage` is a property on
the object, not on `stats`, which the first draft of this got wrong.
