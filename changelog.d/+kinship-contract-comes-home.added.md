`contract/kinship.toml` is new here, and it is the compression plane's own
contract: how a unit is sketched, what "near" means on each channel, the
calibrated grade bands and which direction each improves in, the closed verb
set, the retired spellings that must fail loudly, and how the atlas and shelf
age.

None of it is new text. It lived in the kernel's unified contract nested under a
table named `[irregex]` - named for the package that happened to hold the file
rather than the engine it describes. The nesting is gone; `[irregex.grades]` is
simply `[grades]` now.

`gist` vendors a copy to check its Go, Python, and Rust mirrors against, kept
current by `gist/tools/sync_contract.py`.
