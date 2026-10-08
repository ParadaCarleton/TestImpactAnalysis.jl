# TestImpactAnalysis.jl

[![CI](https://github.com/ParadaCarleton/TestImpactAnalysis.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/ParadaCarleton/TestImpactAnalysis.jl/actions/workflows/CI.yml)

Test impact analysis (regression test selection) for Julia packages: after an edit, run
only the testsets the edit can affect. It uses only the standard library and never loads
the package under test, so it runs from any environment (`julia >= 1.12`).

It expects a test entry file (default `test/runtests.jl`) that holds top-level `@testset`s
with literal names, and a runner script (default `test/runtests.jl`) that runs the testsets
whose name matches a regex given as its first argument, as ReTest does.

## Usage

Install it into an environment of its own, so it never touches the package under test:

```
julia --project=tia -e 'using Pkg; Pkg.add(url = "https://github.com/ParadaCarleton/TestImpactAnalysis.jl")'
```

Then run a command from the root of the package whose tests you want to select:

```
julia --startup-file=no --project=tia -e 'using TestImpactAnalysis; main(ARGS)' COMMAND [options]
```

From a clone, `julia --startup-file=no bin/testimpact.jl COMMAND [options]` does the same.
A typical session maps the suite once, then selects for each branch:

```
testimpact build --source src --jobs 8        # writes test-impact-map.toml
testimpact select --trunk main                # testsets this branch can affect
testimpact run --trunk main                   # select, then run them
```

(`testimpact` standing for either command line above.)

| Command | What it does |
| --- | --- |
| `build` | Runs every top-level testset in its own Julia process under `--code-coverage` and writes the map |
| `merge` | Joins the maps of a sharded build |
| `select` | Prints the testsets a change can affect, each with the rule that chose it, and a regex for the runner |
| `run` | `select`, then runs the selected testsets through the runner |

Options (`--root` defaults to the current directory, `--map` to `ROOT/test-impact-map.toml`):

| Option | Commands | Meaning |
| --- | --- | --- |
| `--tests FILE` | build | Test entry file, searched for testsets and followed through literal `include`s |
| `--source DIR` | build | Source directory to cover; repeatable (default `src`) |
| `--runner FILE` | build, run | Runner script (default `test/runtests.jl`) |
| `--jobs N` | build | Testsets run at once |
| `--timeout SECONDS` | build | Per-testset limit; on timeout the process gets SIGINT, so it still writes its coverage |
| `--only SUBSTRING` | build | Map only matching testsets, for a smoke run |
| `--shard K/N` | build | Map shard K of N |
| `--commit REV` | build | Commit recorded in the map (default `git rev-parse HEAD`) |
| `--env NAME=VALUE` | build | Environment variable for each testset process; repeatable |
| `--in MAP` | merge | A shard map; repeatable |
| `--base REV`, `--trunk REV`, `--to REV` | select, run | Compare `--base` (default `merge-base(TRUNK, TIP)`, TRUNK default `main`) with `--to` (default the working tree, untracked files included; TIP is then `HEAD`) |

## Build the map

Every top-level testset runs in its own process under `--code-coverage=@<source dir>`.
The map records the tree's commit, every source file's function list, and which functions
each testset executed. A runner that starts distributed workers would start them
without the coverage flags: use `--env` to keep each testset in the coverage-flagged process
(for ReTest-style runners, a variable the runner reads).

A build can be split into shards, dealt round-robin by source length and run from one tree
so they share a commit, then joined:

```
for k in 1 2 3 4; do
  testimpact.jl build --source src --jobs 8 --shard $k/4 --map shard-$k-map.toml
done
testimpact.jl merge --map map.toml --in shard-1-map.toml --in shard-2-map.toml ...
```

- In each shard the smallest testset runs alone first, so the coverage-flagged
  precompile is built once. The rest then run `--jobs` at a time, longest first.
- `merge` refuses shards from different commits or files, and a testset mapped twice.
- A testset's status is `ok`, `failed`, `timeout` or `no-coverage`. Only `ok` coverage is
  trusted in full; `select` lists every other status as a note.

## Select

`select` diffs the branch against its own base: `git merge-base TRUNK TIP`, where TIP is
`--to REV` (default `HEAD`) and TRUNK is `--trunk REV` (default `main`). `--base REV`
replaces the merge-base. The other side is the working tree, untracked files included, or
`--to REV`. In a jj workspace that is not colocated, pass `--to <commit of @>`. Each selected
testset is printed with the rule that chose it, followed by a regex for the runner.

| Change | Selected |
| --- | --- |
| `Project.toml` / `Manifest*.toml` (root or a source dir) | the full suite |
| a function's body | testsets that executed a line of it |
| a function's signature, or a method added or removed | testsets that executed any method of that name |
| a struct, abstract/primitive type, const, global, macro, `@enum`, `using`, rule macro… | testsets that executed a function mentioning one of its names, or whose own code mentions it. Names spread through definitions that mention them (`const V = Vector{S}`). |
| a testset | that testset |
| a test helper or test constant | testsets that mention it, transitively |
| a non-`.jl` file under the tests directory | testsets whose code or helpers name the file |
| any `.jl` file | static-analysis testsets: JET, Aqua, `readdir`/`walkdir`/`pkgdir` scans and `names(mod; all = true)` introspection, and testsets using their helpers. A test name counts as such a helper only if every definition of it reads or analyses code or uses such a helper, and it is not one of Base's names: a struct whose constructor method reports through a scanning helper does not make every testset that builds the struct a static-analysis testset. |

- Blank lines, comments and docstrings are ignored. A change counts only if the code
  tokens change.
- A changed function that no testset executed is printed as `UNCOVERED`. So is a new
  function that no testset runs or names.
- A file that does not parse stops the selector with the parser's message.
- The map's commit is not the base, and no base is refused. The map lacks the functions
  added, renamed or re-signed since it was built; `select` prints how many of the changed
  functions that is (`map lacks 2 of 9 changed functions`) and lists them. Those are
  selected by name only (see "What a map knows"). The count says when to rebuild.

## What a map knows

Coverage is keyed by definition, not by line. The map lists each source file's functions
by signature header (the signature with its whitespace removed: `g(x::Int)`,
`(s::S)(y)`), in file order, and a testset's entry names the functions it executed by
position in that list (`functions = { "src/P.jl" = "1-3,9" }`). A function counts as
executed when any line from its signature to its `end` ran. Edits elsewhere in a file
move line numbers but not headers, so a map stays valid while the code around it changes.

- Methods sharing a name are told apart by their headers. If two definitions in one file
  have the same header (for instance under `@static if`), their coverage is joined.
- A function that moves to another file is still found, when that header is defined in
  exactly one other file of the map.
- A renamed or re-signed function has a new header, so the map lacks it. It is selected
  like a new function: by the testsets that executed another method of its name and the
  testsets that mention the name, and printed as `UNCOVERED` when neither exists.
- Only a rebuild refreshes coverage for new, renamed and rewritten code.

## Blind spots

- Coverage comes from one run. A branch taken only on some seeds or thread schedules
  is missed by the testsets that did not take it that time.
- Coverage counts lines, not specializations. A `@generated` body, or code run only at
  compile time, is covered when it is generated. Code inlined into a dependency's
  precompiled image is not covered at all.
- Names are matched as identifiers, with no scope. A local variable that shares a
  changed global's name selects too much. A name reached only through `getfield`,
  `@eval` interpolation or a string selects too little.
- Testsets are run by name. A testset with an interpolated name, or one inside a
  loop, cannot be mapped: `build` stops on the first and warns on the second.
- Code outside the mapped source directories (`scripts/`, `benchmarks/`, registered
  dependencies) is not covered. A change there selects only the static-analysis testsets.
- A static-analysis testset cannot say which files it reads, so any `.jl` change
  selects all of them, a test-only edit included (JET then runs for a test edit).

## Tests

From the package's directory:

```
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
```
