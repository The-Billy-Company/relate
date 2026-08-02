The Python distribution is `relate-search`; the import is still `relate`.
`relate` on PyPI belongs to an unrelated author - a discrete-mathematics
relation library - so the name was never available to publish under, and, worse,
a plain `pip install relate` fetches that stranger's package into a tree that
then imports `relate` and gets whatever it contains. Splitting the two names
closes that: `pip install relate-search`, `import relate`, which is the same
shape bs4, PIL, and cv2 already ship, and the same split `gist-search` made next
door. Only `[project].name` moved; the package directory, the wheel's `packages`
entry, and every `import relate` in the tree are untouched, so nothing a caller
writes changes.

The repository also gets a release workflow, which is what forced the question.
It publishes one `py3-none-any` wheel plus a genuinely buildable sdist through
PyPI Trusted Publishing on a `v*` tag, and refuses to publish a tag that does
not name the declared version. Two gates run before anything leaves: the built
wheel's `Requires-Dist` must resolve from the index, because the
`[tool.uv.sources]` path that makes a local checkout work never reaches core
metadata; and the artifact is installed on the declared 3.12 floor from a
directory that is not the project, so a `requires-python` guess fails here
rather than at someone's import. The binary is not published - the Zig package
is consumed through a tag's tarball, and the CLI is built from source.
