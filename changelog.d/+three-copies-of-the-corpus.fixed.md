- **`relate index` refuses a corpus with no edge, and rations what it writes.**
  Every artifact this verb publishes is corpus-shaped - a sketch per file, a
  silhouette per function, and with `--shelf` a compressed copy of the whole
  corpus. On this monorepo that is 69 + 40 + 87 MB, which is a fine trade in a
  checkout somebody searches all day and a poor one in a folder searched twice.
  Both of the artifact home's laws now bind here: a working directory that is a
  home directory or a filesystem root is not indexed at all (exit 2, with the
  fix), and each tier is admitted only inside the tree's disk allowance
  (`GIST_DISK_MB`, default 512 MiB), charged in the order the tiers are worth
  having so a tree just past the ceiling loses the last one rather than all of
  them.

  Declining is loud and costs no answer: `similar`, `echoes`, `pack` and
  `quote` all have a live path that says the same thing more slowly, which is
  what an accelerator declining is supposed to mean.
