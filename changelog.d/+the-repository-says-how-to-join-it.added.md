The repository had a license, a NOTICE, and five CI jobs, and nothing that told
a contributor how to work in it. It now carries the paper trail a public
project is supposed to have.

[`CONTRIBUTING.md`](CONTRIBUTING.md) is the practical half: that this package
cannot build from its own clone and needs `irregex` and `gist` beside it, what
each toolchain is pinned by, how to use the sharded suite instead of paying for
the whole thing, and why every binding suite skips itself into a green run
unless you build the binary first. It also states the constraints a change is
actually held to - there are two kinship questions and a new verb has to argue
it is not an axis; a warm answer is byte-identical to a cold one or the atlas is
broken; a grade band is a claim about what "kin" means and moves
`contract/kinship.toml` with it.

[`SECURITY.md`](SECURITY.md) names the threat model this face has that its
siblings do not. The corpus is the attacker, as everywhere - but `quote` and
`pack` make **attributions**, and someone acts on those. A phrase attributed to
a file that never held it, an artifact that moves a distance, or a kept answer
that outlives its epoch is a security report here rather than a bug. It says
what is not one, too: pairwise sweeps cost what pairs cost.

[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) is Contributor Covenant 3.0, with
reports going to a maintainer address rather than a committee that does not
exist. Its "failing to credit sources" clause is not boilerplate here: the
prior-art dossier's verdict on this whole engine is COMPOSITION, and that word
is only honest if every ingredient is cited at the point of use.

The dotfiles are small and load-bearing. `.editorconfig` restates what each
formatter already emits, so an editor save and `zig fmt --check` cannot
disagree. `.gitattributes` normalizes line endings - kinship is measured over
bytes, so a CRLF checkout would move every distance in the atlas - marks
resolver output as generated, binds the hunk-header drivers, and deliberately
declines `export-ignore`, which would invalidate every url+hash pin that already
exists. `.mailmap` collapses four author spellings into two people.

On GitHub: `CODEOWNERS` routes review, Dependabot watches the one ecosystem it
can actually resolve here, a pull-request template asks the three questions
review always asks anyway, and the issue forms ask for the corpus. The kinship
form's most useful field is whether `--no-index` changes the answer, because it
splits "the metric is wrong" from "the atlas is lying" before anyone reads code.
