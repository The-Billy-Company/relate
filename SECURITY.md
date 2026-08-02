# Security Policy

`relate` is pointed at trees it did not write. You clone a repository you have
never read and ask what repeats in it; an agent sketches a checkout ten other
agents are editing. So the threat model here is not "someone attacks the binary"
so much as **"the corpus is the attacker"** - hostile file names, hostile bytes,
a committed config file, a persisted atlas left behind by something else. Every
one of those is input.

There is a second axis this face has and its siblings do not: `relate` makes
**claims about provenance**. `quote` says a passage came from a particular file,
and `pack` says a set of files explains a text. A wrong answer there is not a
missing search hit - it is an attribution, and someone may act on it.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion.**

Use GitHub's private reporting - the **Security** tab on this repository,
"Report a vulnerability" - which opens a thread only the maintainers can read.
If that is unavailable to you, email **<security@billylives.com>**.

Please include:

- what you found and what it lets an attacker do;
- the smallest reproduction you can manage: the tree (a script that builds it
  beats a tarball), the exact command line, and whether the atlas or the shelf
  was warm;
- `relate --version`, plus `relate status --json` if the persisted artifacts are
  involved;
- your OS and architecture, and how you built or installed the binary.

We will acknowledge within **72 hours** and give you a triage verdict with a
severity within **7 days**. If it is real we will agree a disclosure date with
you, credit you in the changelog fragment and the release notes unless you would
rather we did not, and ship the fix before the details go public. There is no
paid bounty.

We will not pursue anyone who reports in good faith, works against their own
machines and their own data, and gives us a reasonable window to fix the thing
before publishing.

## Supported versions

Pre-1.0, and the version number says so. Fixes land on `main` and ship in the
next release; there are no maintained release branches and no backports to
earlier tags. Watch releases on this repository if you pin.

Two neighbors carry their own policies. The engine underneath is
[`irregex`][irregex]: the regex engines, the corpus walk, the FM-index the
quotation parse runs over, and the freshness law are all its. The chassis is
[`gist`][gist]: argv, the resident daemon, and the answer keep. A memory-safety
bug in either is theirs. Any tracker reaches us, and we will move a report
rather than bounce you.

## What we consider a vulnerability here

- **An accelerator that changes an answer.** The stated law is that the tree
  tells the truth: the kinship atlas, the fragment atlas, the codex shelf, and
  the answer keep may all save work, and none of them may change the result.
  A warm answer is supposed to be byte-identical to a cold one. A crafted or
  corrupt artifact that moves a distance, invents kin, hides a family, or
  replays a result the corpus no longer supports breaks the promise the whole
  design rests on. Report it as security, not as a bug.
- **A false attribution.** `quote` names a source file for each verbatim phrase
  and `pack` names the files that explain a text. Input that makes either point
  at a file which never contained the phrase - or that lets a file in the corpus
  claim text it does not hold - is in scope. So is a phrase surviving into an
  answer after the bytes that justified it are gone.
- **A config file reaching past its ceiling.** A tree's committed
  `.irregex.toml` is read from the corpus you are searching, which means a
  repository you cloned gets a vote. Its reach is capped at **corpus**: it may
  say what the repository *is* (roots, skips, extra type names) and may never
  change what *matches* or what *ranks*, never run a command, and never read a
  path outside the tree. A charter that escapes that ceiling is a vulnerability.
- **Escaping the scope you were given.** A symlink, a `..` in a name, or a path
  spelling that walks a sweep out of its roots. `--matching` requires `ROOT...`
  or an explicit `--all` precisely so that a composed query can never silently
  sweep `vendor/` or `upstream/`; something that defeats that is in scope.
- **Terminal escape injection.** Paths, quoted phrases, and matched bytes are
  printed, and OSC-8 hyperlinks are emitted when stdout is an interactive
  terminal. Content that can drive a terminal emulator - relocate the cursor,
  rewrite earlier output, set the title, or forge a link target that does not
  match its label - is in scope. A pipe, a redirect, and `--json` are supposed
  to be plain bytes with none of that layer; if any of them is not, that is the
  report.
- **The answer keep crossing a boundary.** A kept answer is held against a
  corpus change epoch, for one user, within one output envelope. Anything that
  serves one user's rendered bytes to another, that survives a corpus change, or
  that lets an interactive run and a piped run share an entry is a
  vulnerability - not a caching bug.
- **Memory safety anywhere in this repository.** Release builds are
  `ReleaseFast`, where Zig's safety checks are off, so a bug that is a clean
  panic in your debug build may be memory corruption in the shipped binary. The
  sketching and anatomy paths parse arbitrary bytes from files nobody vetted,
  which is exactly where to look.

## What is not a vulnerability

- **Cost proportional to the corpus.** `echoes` asks a question about pairs, and
  `--shape distinct` is a claim about every pair. A big tree costs more than a
  small one. That is arithmetic, and the answer keep exists because of it.
- **A grade you disagree with.** The bands are calibrated and declared in
  [`contract/kinship.toml`](contract/kinship.toml). A neighbor you expected to
  see is a quality issue worth filing as a bug, with the corpus - not a security
  report.
- **The daemon obeying the user who started it.** Same-user access is the
  design, not a hole.
- **A stale answer you asked for.** `quote` reads the persisted shelf by
  design; re-verification against current bytes is `blast provenance`, in the
  [`blast`][blast] repository. Documented staleness is a trade, not a defect -
  an answer the shelf never justified is the defect.

## What already tries to catch this

None of it is a guarantee, and finding something these missed is exactly the
kind of report we want:

- the warm tier is checked against a live rebuild rather than trusted: an atlas
  answer that is not byte-identical to the cold one is a test failure, and
  `--no-index` lets you run that comparison yourself on any tree, any time;
- a missing or corrupt artifact degrades to a live build instead of failing or
  guessing, so the accelerator can never be load-bearing for correctness;
- the suite runs ReleaseSafe by design, because the differential suites exist
  partly to trip the safety checks a release build elides, on Linux and macOS
  both;
- an architecture contract ([`contract/relate.ward`](contract/relate.ward)) that
  machine-checks the import topology, and a vocabulary contract
  ([`contract/kinship.toml`](contract/kinship.toml)) that the sibling bindings
  are checked against;
- a falsification record kept in the open
  ([`research/relate/TESTING.md`](research/relate/TESTING.md)), including the
  things that did not work.

## Provenance

[`NOTICE`](NOTICE) records what is borrowed and from whom. The algorithms here
are implemented from published descriptions rather than from borrowed source;
[`research/relate/PRIOR_ART.md`](research/relate/PRIOR_ART.md) is the citation
trail, and the C floors this package uses arrive through `irregex` with their
notices attached.

[irregex]: https://github.com/The-Billy-Company/irregex/blob/main/SECURITY.md
[gist]: https://github.com/The-Billy-Company/gist/blob/main/SECURITY.md
[blast]: https://github.com/The-Billy-Company/blast
