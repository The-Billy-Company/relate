A face with one verb everybody types still made you type it. `blast blast Corpus` is the shape the manifest forced, and the stutter is not a naming accident - it is the dispatcher having no way to hear a bare argument as a verb's argument.

A `Face` can now declare `bare`, the verb that runs when `argv[1]` is not one. `bareFor` resolves it only when the token collides with no verb, no retired name, and no flag, so `blast index` still means the verb and `blast -h` still means help; a symbol that happens to share a verb's name stays reachable by spelling the verb out.

`--schema` reports the default so an agent can see it without guessing, and the help renderer shows the verbless form as the invocation.
