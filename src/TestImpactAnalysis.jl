"""
    TestImpactAnalysis

Test impact analysis (regression test selection): run only the tests a change can affect.
Works for any Julia package whose testsets can be run by name through a runner script that
takes a regex (ReTest's convention).

  build   run every top-level testset in its own process with `--code-coverage` and save
          which source lines each one executed, with the git commit of the tree
  merge   join the maps of a sharded build
  select  compare the working tree (or `--to REV`) with a base and print the testsets
          whose executed code, or whose referenced definitions, changed
  run     select, then run the selected testsets through the runner

Standard library only; it never loads the package under test. See README.md.
"""
module TestImpactAnalysis

using Dates: Dates
using SHA: SHA
using TOML: TOML
import Base.JuliaSyntax as JS
using Base.JuliaSyntax: @K_str

export main

# ---------------------------------------------------------------------------------------
# Items: the top-level definitions of a Julia file
# ---------------------------------------------------------------------------------------

"""
One top-level item of a file. `kind` is `:function`, `:binding` (struct, abstract or
primitive type, const, global, assignment, macro), `:testset`, `:include` or `:other`.
`keys` are the names the item defines (empty for `:other`), `mentions` every identifier
inside it, `header` a function's signature without whitespace, and `doc_first:doc_last`
the docstring's lines (`0:-1` for none).
"""
struct Item
    kind::Symbol
    name::String
    keys::Vector{String}
    first::Int
    last::Int
    doc_first::Int
    doc_last::Int
    mentions::Set{String}
    includes::Vector{String}
    header::String
    text::String
end

"An item and the file it came from."
struct Located
    path::String
    item::Item
end

item_start(item::Item)::Int = item.first

first_line(node::JS.SyntaxNode)::Int = JS.source_line(node)

function last_line(node::JS.SyntaxNode)::Int
    return first(JS.source_location(node.source, last(JS.byte_range(node))))
end

"""
    identifier_texts(node)

Every identifier and macro name below `node`, without the `@` of a macro.
"""
function identifier_texts(node::JS.SyntaxNode)::Vector{String}
    if JS.is_leaf(node)
        if JS.kind(node) == K"Identifier"
            return [String(JS.sourcetext(node))]
        end
        return String[]
    end
    return reduce(vcat, (identifier_texts(part) for part in JS.children(node)); init = String[])
end

"The value of a string literal with no interpolation; empty for anything else."
function literal_string(node::JS.SyntaxNode)::String
    if JS.kind(node) == K"string"
        parts = JS.children(node)
        if length(parts) == 1 && JS.kind(first(parts)) == K"String"
            return String(first(parts).val)
        end
    end
    return ""
end

"Literal paths of the `include(\"...\")` calls below `node`."
function include_paths(node::JS.SyntaxNode)::Vector{String}
    if JS.is_leaf(node)
        return String[]
    end
    parts = JS.children(node)
    if JS.kind(node) == K"call" && length(parts) == 2 && String(JS.sourcetext(first(parts))) == "include"
        path = literal_string(last(parts))
        if !isempty(path)
            return [path]
        end
    end
    return reduce(vcat, (include_paths(part) for part in parts); init = String[])
end

"The name a function signature defines (a callable object's methods share `(callable)`)."
function callee_name(node::JS.SyntaxNode)::String
    kind = JS.kind(node)
    if kind == K"call"
        parts = JS.children(node)
        if JS.is_prefix_call(node)
            return callee_name(first(parts))
        end
        return String(JS.sourcetext(parts[2]))
    end
    if kind in (K"where", K"::", K"curly")
        return callee_name(first(JS.children(node)))
    end
    if kind == K"parens"
        return "(callable)"
    end
    if kind == K"."
        return String(last(split(JS.sourcetext(node), '.')))
    end
    return String(JS.sourcetext(node))
end

"The name of a `struct`, `abstract type` or `primitive type` header."
function type_name(node::JS.SyntaxNode)::String
    if JS.kind(node) in (K"<:", K"curly")
        return type_name(first(JS.children(node)))
    end
    return String(JS.sourcetext(node))
end

"The names an assignment or declaration target binds."
function binding_targets(node::JS.SyntaxNode)::Vector{String}
    kind = JS.kind(node)
    if kind == K"Identifier"
        return [String(JS.sourcetext(node))]
    end
    if kind in (K"::", K"=")
        return binding_targets(first(JS.children(node)))
    end
    if kind in (K"tuple", K"parens")
        return reduce(vcat, (binding_targets(part) for part in JS.children(node)); init = String[])
    end
    return String[]
end

"The definition a macro call wraps: the last argument, through nested macro calls."
function unwrap_macro(node::JS.SyntaxNode)::JS.SyntaxNode
    if JS.kind(node) == K"macrocall"
        parts = JS.children(node)
        if length(parts) > 1
            return unwrap_macro(last(parts))
        end
    end
    return node
end

"The `@testset` calls reachable from `node` through macro calls (`@changeprecision X @testset ...`)."
function testset_nodes(node::JS.SyntaxNode)::Vector{JS.SyntaxNode}
    if JS.kind(node) == K"macrocall"
        parts = JS.children(node)
        if String(JS.sourcetext(first(parts))) == "@testset"
            return [node]
        end
        return reduce(vcat, (testset_nodes(part) for part in parts); init = JS.SyntaxNode[])
    end
    return JS.SyntaxNode[]
end

"A testset's literal name; empty when it is interpolated."
function testset_name(node::JS.SyntaxNode)::String
    names = String[literal_string(part) for part in JS.children(node) if JS.kind(part) == K"string"]
    if isempty(names)
        return ""
    end
    return first(names)
end

"`(kind, name, keys, header)` of a definition node."
function describe_core(core::JS.SyntaxNode)::Tuple{Symbol,String,Vector{String},String}
    if JS.is_leaf(core)
        return (:other, "", String[], "")
    end
    kind = JS.kind(core)
    parts = JS.children(core)
    if kind == K"function"
        signature = first(parts)
        name = callee_name(signature)
        return (:function, name, [name], replace(JS.sourcetext(signature), r"\s+" => ""))
    end
    if kind in (K"struct", K"abstract", K"primitive")
        name = type_name(first(parts))
        return (:binding, name, [name], "")
    end
    if kind == K"macro"
        name = callee_name(first(parts))
        return (:binding, name, [name], "")
    end
    if kind in (K"const", K"global", K"local")
        targets = reduce(vcat, (binding_targets(part) for part in parts); init = String[])
        return (:binding, "", targets, "")
    end
    if kind == K"="
        return (:binding, "", binding_targets(first(parts)), "")
    end
    if kind == K"call" && String(JS.sourcetext(first(parts))) == "include"
        return (:include, "", String[], "")
    end
    return (:other, "", String[], "")
end

function build_item(
        whole::JS.SyntaxNode,
        description::Tuple{Symbol,String,Vector{String},String},
        doc::UnitRange{Int},
    )::Item
    kind, name, keys, header = description
    return Item(
        kind,
        name,
        keys,
        first_line(whole),
        last_line(whole),
        first(doc),
        last(doc),
        Set(identifier_texts(whole)),
        include_paths(whole),
        header,
        String(JS.sourcetext(whole)),
    )
end

function node_items(node::JS.SyntaxNode, doc::UnitRange{Int})::Vector{Item}
    kind = JS.kind(node)
    if kind == K"module"
        block = last(JS.children(node))
        return reduce(vcat, (node_items(part, 0:-1) for part in JS.children(block)); init = Item[])
    end
    if kind == K"doc"
        parts = JS.children(node)
        return node_items(last(parts), first_line(first(parts)):last_line(first(parts)))
    end
    found = testset_nodes(node)
    if !isempty(found)
        name = testset_name(first(found))
        return [build_item(node, (:testset, name, [name], ""), doc)]
    end
    if kind == K"macrocall"
        return [build_item(node, describe_core(unwrap_macro(node)), doc)]
    end
    return [build_item(node, describe_core(node), doc)]
end

"""
    parse_source(text, label)

The syntax tree of a file; a file that does not parse is an error naming `label` and
carrying the parser's message.
"""
function parse_source(text::AbstractString, label::AbstractString)::JS.SyntaxNode
    try
        return JS.parseall(JS.SyntaxNode, text; filename = label)
    catch exception
        if exception isa JS.ParseError
            error("cannot parse ", label, ":\n", sprint(showerror, exception))
        end
        rethrow()
    end
end

"The top-level items of a file (modules are entered; their own line is not an item)."
function source_items(text::AbstractString, label::AbstractString)::Vector{Item}
    parts = JS.children(parse_source(text, label))
    if isnothing(parts)
        return Item[]
    end
    return reduce(vcat, (node_items(part, 0:-1) for part in parts); init = Item[])
end

# ---------------------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------------------

function git(root::AbstractString, args::AbstractString...)::String
    return read(`git -C $root -c core.quotepath=off --no-pager $(collect(args))`, String)
end

"A tree to read files from: revision `revision` of the repository, or the working tree when empty."
struct Snapshot
    root::String
    revision::String
end

function read_file(snapshot::Snapshot, path::AbstractString)::String
    if isempty(snapshot.revision)
        return read(joinpath(snapshot.root, path), String)
    end
    return git(snapshot.root, "show", string(snapshot.revision, ":", path))
end

function label(snapshot::Snapshot, path::AbstractString)::String
    if isempty(snapshot.revision)
        return String(path)
    end
    return string(first(snapshot.revision, 10), ":", path)
end

"The items of `path` at `snapshot`, followed by the items of each file it includes, recursively."
function located_items(snapshot::Snapshot, path::AbstractString)::Vector{Located}
    items = source_items(read_file(snapshot, path), label(snapshot, path))
    return reduce(vcat, (included_items(snapshot, path, item) for item in items); init = Located[])
end

function included_items(snapshot::Snapshot, path::AbstractString, item::Item)::Vector{Located}
    nested = (located_items(snapshot, normpath(joinpath(dirname(path), file))) for file in item.includes)
    return vcat([Located(String(path), item)], reduce(vcat, nested; init = Located[]))
end

struct Hunk
    old_first::Int
    old_count::Int
    new_first::Int
    new_count::Int
    removed::Vector{String}
    added::Vector{String}
end

struct FileChange
    path::String
    status::Symbol
    hunks::Vector{Hunk}
end

count_or_one(text::AbstractString)::Int = isempty(text) ? 1 : parse(Int, text)

function parse_hunk(chunk::AbstractString)::Hunk
    lines = split(chunk, '\n')
    found = match(r"^-(\d+),*(\d*) \+(\d+),*(\d*) @@", first(lines))
    return Hunk(
        parse(Int, found[1]),
        count_or_one(found[2]),
        parse(Int, found[3]),
        count_or_one(found[4]),
        String[chopprefix(line, "-") for line in Iterators.drop(lines, 1) if startswith(line, "-")],
        String[chopprefix(line, "+") for line in Iterators.drop(lines, 1) if startswith(line, "+")],
    )
end

function parse_file_change(chunk::AbstractString)::FileChange
    pieces = split(chunk, r"^@@ "m)
    header = first(pieces)
    found = match(r"^a/(.+) b/(.+)\n", header)
    status = :modified
    if occursin(r"^new file mode"m, header)
        status = :added
    end
    if occursin(r"^deleted file mode"m, header)
        status = :deleted
    end
    hunks = [parse_hunk(piece) for piece in Iterators.drop(pieces, 1)]
    return FileChange(String(found[2]), status, hunks)
end

parse_diff(text::AbstractString)::Vector{FileChange} =
    [parse_file_change(chunk) for chunk in split(text, r"^diff --git "m; keepempty = false)]

"A file git does not track yet, as a change that adds all its lines."
function untracked_change(root::AbstractString, path::AbstractString)::FileChange
    if endswith(path, ".jl")
        lines = readlines(joinpath(root, path))
        return FileChange(String(path), :added, [Hunk(0, 0, 1, length(lines), String[], lines)])
    end
    return FileChange(String(path), :added, Hunk[])
end

"""
    file_changes(root, base, target)

The files that differ between revision `base` and `target` (the working tree, untracked
files included, when `target` is empty), without rename detection: a rename is a deletion
and an addition.
"""
function file_changes(root::AbstractString, base::AbstractString, target::AbstractString)::Vector{FileChange}
    revisions = filter(!isempty, [String(base), String(target)])
    tracked = parse_diff(git(root, "diff", "--no-renames", "--no-color", "--no-ext-diff", "-U0", revisions..., "--"))
    if !isempty(target)
        return tracked
    end
    listing = git(root, "ls-files", "--others", "--exclude-standard")
    untracked = [untracked_change(root, path) for path in split(listing, '\n'; keepempty = false)]
    return vcat(tracked, untracked)
end

"Blob hash of every file at `revision`, as `git ls-tree` reports it."
function tree_blobs(root::AbstractString, revision::AbstractString)::Dict{String,String}
    listing = git(root, "ls-tree", "-r", "--full-tree", revision)
    rows = [split(row, r"[ \t]"; limit = 4) for row in split(listing, '\n'; keepempty = false)]
    return Dict(String(row[4]) => String(row[3]) for row in rows)
end

"The `.jl` files under the `sources` directories at `revision`."
function source_files(root::AbstractString, revision::AbstractString, sources::AbstractVector{<:AbstractString})::Vector{String}
    return sort([
        path for path in keys(tree_blobs(root, revision))
            if endswith(path, ".jl") && any(startswith(path, string(dir, "/")) for dir in sources)
    ])
end

# ---------------------------------------------------------------------------------------
# Coverage map
# ---------------------------------------------------------------------------------------

"""
One testset's coverage: its status, wall time, and for each source file the signature
headers of the functions it executed (a function counts as run when any of its lines,
signature to `end`, ran).
"""
struct TestsetCoverage
    status::String
    ms::Int
    functions::Dict{String,Set{String}}
end

"""
A coverage map. `definitions` lists each source file's function headers at `commit`, in
file order, and a testset's coverage names functions by their position in that list. A
function is known by its file and its signature header without whitespace, so methods
sharing a name are told apart by their arguments, and an edit elsewhere in the file
leaves the identity alone.
"""
struct CoverageMap
    commit::String
    tests::String
    sources::Vector{String}
    runner::String
    definitions::Dict{String,Vector{String}}
    testsets::Dict{String,TestsetCoverage}
end

"Sorted line numbers as `1-5,9,12-30`."
function ranges_text(lines::AbstractVector{<:Integer})::String
    sorted = sort(unique(lines))
    if isempty(sorted)
        return ""
    end
    run_stops = vcat(findall(!=(1), diff(sorted)), length(sorted))
    run_starts = vcat(1, run_stops[1:(end - 1)] .+ 1)
    return join((run_text(sorted[run_start], sorted[run_stop]) for (run_start, run_stop) in zip(run_starts, run_stops)), ',')
end

function run_text(low::Integer, high::Integer)::String
    if low == high
        return string(low)
    end
    return string(low, '-', high)
end

function parse_ranges(text::AbstractString)::Vector{UnitRange{Int}}
    bounds = [split(token, '-') for token in split(text, ','; keepempty = false)]
    return [parse(Int, first(pair)):parse(Int, last(pair)) for pair in bounds]
end

"The headers at `positions` (as `ranges_text` writes them) of a file's function list."
function headers_at(headers::AbstractVector{String}, positions::AbstractString)::Set{String}
    return Set(headers[position] for range in parse_ranges(positions) for position in range)
end

function read_map(path::AbstractString)::CoverageMap
    document = TOML.parsefile(path)
    if !haskey(document, "definitions")
        error(path, " is a line map from before definition identities; rebuild it with `build`")
    end
    meta = document["meta"]
    definitions = Dict(String(file) => String[headers...] for (file, headers) in document["definitions"])
    testsets = Dict(
        String(name) => TestsetCoverage(
                entry["status"],
                entry["ms"],
                Dict(String(file) => headers_at(definitions[file], positions) for (file, positions) in entry["functions"]),
            ) for (name, entry) in document["testsets"]
    )
    return CoverageMap(meta["commit"], meta["tests"], String[meta["sources"]...], meta["runner"], definitions, testsets)
end

"""
    mapped_file(map, path, item)

The file whose map definitions hold function `item`'s header: `path` itself, else the
one other file defining that header (the function moved since the map was built). Empty
when the map has no such function: it was added, renamed or re-signed since the map was
built, or its header is defined in several other files.
"""
function mapped_file(map::CoverageMap, path::AbstractString, item::Item)::String
    if item.header in get(map.definitions, path, String[])
        return String(path)
    end
    holders = [file for (file, headers) in map.definitions if item.header in headers]
    if length(holders) == 1
        return only(holders)
    end
    return ""
end

"Names of the map's testsets that executed function `item`."
function covering(map::CoverageMap, path::AbstractString, item::Item)::Vector{String}
    file = mapped_file(map, path, item)
    return sort([name for (name, entry) in map.testsets if item.header in get(entry.functions, file, Set{String}())])
end

# ---------------------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------------------

"""
Names whose use marks code that reads source files or analyses the whole package (JET,
Aqua, file scans): such a testset depends on every source file, not on the lines it runs.
"""
const STATIC_MARKERS = Set(["walkdir", "readdir", "pkgdir", "pathof", "Aqua", "test_opt", "test_call", "test_package", "report_opt", "report_call", "report_package"])

"Whether `item` reads or analyses code: a marker name, or listing a module's names (`names(mod; all = true)`)."
function static_item(item::Item)::Bool
    return !isdisjoint(item.mentions, STATIC_MARKERS) || occursin(r"\bnames\([^()]*all\s*=\s*true", item.text)
end

"""
The result of a selection: `reasons` pairs a testset name with the rule that selected it,
`full` lists why the whole suite must run, `uncovered` the changed functions no testset
executed, and `notes` everything else the reader should know.
"""
struct Selection
    reasons::Vector{Pair{String,String}}
    full::Vector{String}
    uncovered::Vector{String}
    notes::Vector{String}
end

"The hunks' touched old items and new items."
struct Delta
    path::String
    old_hit::Vector{Item}
    new_hit::Vector{Item}
end

function in_doc(items::AbstractVector{Item}, number::Integer)::Bool
    return any(item.doc_first <= number <= item.doc_last for item in items)
end

function ignorable_line(text::AbstractString, number::Integer, items::AbstractVector{Item})::Bool
    stripped = strip(text)
    return isempty(stripped) || startswith(stripped, "#") || in_doc(items, number)
end

"The source tokens of `lines`, without whitespace and comments."
function code_tokens(lines::AbstractVector{<:AbstractString})::Vector{String}
    text = join(lines, '\n')
    return [String(JS.untokenize(token, text)) for token in JS.tokenize(text) if !JS.is_whitespace(JS.kind(token))]
end

"""
Whether a hunk changes nothing but blanks, comments and docstrings: the lines outside
docstrings carry the same tokens before and after.
"""
function ignorable(hunk::Hunk, old_items::AbstractVector{Item}, new_items::AbstractVector{Item})::Bool
    removed = [
        text for (offset, text) in enumerate(hunk.removed) if !ignorable_line(text, hunk.old_first + offset - 1, old_items)
    ]
    added = [
        text for (offset, text) in enumerate(hunk.added) if !ignorable_line(text, hunk.new_first + offset - 1, new_items)
    ]
    return code_tokens(removed) == code_tokens(added)
end

function overlapping(items::AbstractVector{Item}, low::Integer, high::Integer)::Vector{Item}
    return [item for item in items if item.first <= high && item.last >= low]
end

"Old items a hunk touches; an insertion touches the item it lands inside."
function items_hit_old(items::AbstractVector{Item}, hunk::Hunk)::Vector{Item}
    if hunk.old_count > 0
        return overlapping(items, hunk.old_first, hunk.old_first + hunk.old_count - 1)
    end
    return [item for item in items if item.first <= hunk.old_first && hunk.old_first < item.last]
end

function items_hit_new(items::AbstractVector{Item}, hunk::Hunk)::Vector{Item}
    if hunk.new_count > 0
        return overlapping(items, hunk.new_first, hunk.new_first + hunk.new_count - 1)
    end
    return Item[]
end

function items_at(snapshot::Snapshot, path::AbstractString, present::Bool)::Vector{Item}
    if !present
        return Item[]
    end
    return source_items(read_file(snapshot, path), label(snapshot, path))
end

"""
    file_delta(old_snapshot, new_snapshot, change)

Parse the file on both sides and keep the items touched by hunks that change more than
blanks, comments and docstrings. A file that does not parse raises an error.
"""
function file_delta(old_snapshot::Snapshot, new_snapshot::Snapshot, change::FileChange)::Delta
    old_items = items_at(old_snapshot, change.path, change.status != :added)
    new_items = items_at(new_snapshot, change.path, change.status != :deleted)
    hunks = [hunk for hunk in change.hunks if !ignorable(hunk, old_items, new_items)]
    old_hit = unique(item_start, reduce(vcat, (items_hit_old(old_items, hunk) for hunk in hunks); init = Item[]))
    new_hit = unique(item_start, reduce(vcat, (items_hit_new(new_items, hunk) for hunk in hunks); init = Item[]))
    return Delta(change.path, old_hit, new_hit)
end

function headers(items::AbstractVector{Item}, name::AbstractString)::Vector{String}
    return sort([item.header for item in items if item.name == name])
end

"Function names whose set of signatures differs between the old and new touched items."
function widened_names(delta::Delta)::Vector{String}
    old_functions = [item for item in delta.old_hit if item.kind == :function]
    new_functions = [item for item in delta.new_hit if item.kind == :function]
    names = unique(vcat([item.name for item in old_functions], [item.name for item in new_functions]))
    return [name for name in names if headers(old_functions, name) != headers(new_functions, name)]
end

"The names a non-function item is known by; an item that defines none is known by what it mentions."
function binding_keys(item::Item)::Vector{String}
    if item.kind == :include
        return String[]
    end
    if item.kind == :function
        return [item.name]
    end
    if isempty(item.keys)
        return sort([name for name in item.mentions if !isdefined(Base, Symbol(name))])
    end
    return item.keys
end

"The changed names of a delta: what its touched non-function items define, old and new."
function delta_names(delta::Delta)::Vector{String}
    touched = [item for item in vcat(delta.old_hit, delta.new_hit) if item.kind in (:binding, :other)]
    return unique(reduce(vcat, (binding_keys(item) for item in touched); init = String[]))
end

"""
`seeds` plus every name defined by an item that mentions a name already in the set. Only
items that define names spread a change: a `using` line or a rule macro mentioning a
changed name defines nothing new.
"""
function name_closure(seeds::Set{String}, binders::AbstractVector{Located})::Set{String}
    grown = union(
        seeds,
        reduce(
            vcat,
            (binder.item.keys for binder in binders if !isdisjoint(binder.item.mentions, seeds));
            init = String[],
        ),
    )
    if length(grown) == length(seeds)
        return seeds
    end
    return name_closure(grown, binders)
end

function describe_item(path::AbstractString, item::Item)::String
    return string(path, ":", item.first, "-", item.last)
end

"Testsets that run `item`, each paired with the rule that selected it."
function by_coverage(
        map::CoverageMap,
        path::AbstractString,
        item::Item,
        rule::AbstractString,
    )::Vector{Pair{String,String}}
    return [name => string(rule, " (", describe_item(path, item), ")") for name in covering(map, path, item)]
end

function full_suite_reasons(changes::AbstractVector{FileChange}, sources::AbstractVector{<:AbstractString})::Vector{String}
    return [string(change.path, " changed") for change in changes if dependency_file(change.path, sources)]
end

function dependency_file(path::AbstractString, sources::AbstractVector{<:AbstractString})::Bool
    name = basename(path)
    named = name == "Project.toml" || (startswith(name, "Manifest") && endswith(name, ".toml"))
    placed = !occursin('/', path) || any(startswith(path, string(dir, "/")) for dir in sources)
    return named && placed
end

function path_class(
        path::AbstractString,
        test_paths::AbstractSet{String},
        test_dir::AbstractString,
        sources::AbstractVector{<:AbstractString},
    )::Symbol
    if !endswith(path, ".jl")
        if startswith(path, string(test_dir, "/"))
            return :fixture
        end
        return :ignored
    end
    if path in test_paths
        return :test
    end
    if any(startswith(path, string(dir, "/")) for dir in sources)
        return :source
    end
    return :other
end

"""
    select_testsets(root, map, base, target)

Select the map's testsets affected by the change from revision `base` to `target` (the
working tree when `target` is empty). Rules, in the order they appear in the reasons:

  * full suite: a `Project.toml` or `Manifest.toml` changed
  * runs changed code: the testset executed a line of a function whose body changed
  * dispatch: a function's signatures were added, removed or edited, so any testset that ran
    any method of that name may now dispatch differently
  * mentions changed definition: a struct, type, const, global, macro or other non-function
    item changed, and the testset executed a function that mentions its name (or a name
    defined by something that mentions it), or its own code mentions it
  * edited testset, new testset, changed test helper, changed fixture file
  * static analysis: the testset reads or analyses code and any `.jl` file changed
"""
function select_testsets(
        root::AbstractString,
        map::CoverageMap,
        base::AbstractString,
        target::AbstractString,
    )::Selection
    changes = file_changes(root, base, target)
    old_snapshot = Snapshot(String(root), String(base))
    new_snapshot = Snapshot(String(root), String(target))
    old_tests = located_items(old_snapshot, map.tests)
    new_tests = located_items(new_snapshot, map.tests)
    test_paths = Set(vcat([map.tests], [located.path for located in vcat(old_tests, new_tests)]))
    test_dir = dirname(map.tests)
    classes = [path_class(change.path, test_paths, test_dir, map.sources) for change in changes]
    runnable = Set(located.item.name for located in new_tests if located.item.kind == :testset)

    full = full_suite_reasons(changes, map.sources)
    if !isempty(full)
        everything = [name => "full suite: " * reason for name in sort(collect(runnable)) for reason in full]
        return Selection(everything, full, String[], String[])
    end

    source_deltas = [file_delta(old_snapshot, new_snapshot, change) for (change, class) in zip(changes, classes) if class == :source]
    test_deltas = [file_delta(old_snapshot, new_snapshot, change) for (change, class) in zip(changes, classes) if class == :test]
    any_jl = any(endswith(change.path, ".jl") for change in changes)

    changed = reduce(
        vcat,
        (
            [Located(delta.path, item) for item in delta.old_hit if item.kind == :function] for delta in source_deltas
        );
        init = Located[],
    )
    lacking = [located for located in changed if isempty(mapped_file(map, located.path, located.item))]
    executed = [located for located in changed if !isempty(mapped_file(map, located.path, located.item))]
    run_reasons = reduce(
        vcat,
        (by_coverage(map, located.path, located.item, "runs changed `" * located.item.name * "`") for located in executed);
        init = Pair{String,String}[],
    )
    uncovered = [
        string("changed function `", located.item.name, "` (", describe_item(located.path, located.item), "): no testset ran it") for located in executed
            if isempty(covering(map, located.path, located.item))
    ]

    old_sources = reduce(
        vcat,
        (
            [Located(path, item) for item in items_at(old_snapshot, path, true)] for path in source_files(root, base, map.sources)
        );
        init = Located[],
    )
    widened = unique(
        vcat(
            reduce(vcat, (widened_names(delta) for delta in source_deltas); init = String[]),
            [located.item.name for located in lacking],
        ),
    )
    dispatch_reasons = reduce(
        vcat,
        (
            by_coverage(map, located.path, located.item, "dispatch: methods of `" * located.item.name * "` changed") for
                located in old_sources if located.item.kind == :function && located.item.name in widened
        );
        init = Pair{String,String}[],
    )

    source_seeds = Set(reduce(vcat, (delta_names(delta) for delta in source_deltas); init = String[]))
    source_binders = [located for located in old_sources if located.item.kind in (:binding, :other)]
    source_names = name_closure(source_seeds, source_binders)
    mention_reasons = reduce(
        vcat,
        (
            by_coverage(
                    map,
                    located.path,
                    located.item,
                    "mentions changed definition `" * first(sort(collect(intersect(located.item.mentions, source_names)))) * "`",
                ) for located in old_sources
                if located.item.kind == :function && !isdisjoint(located.item.mentions, source_names)
        );
        init = Pair{String,String}[],
    )

    new_testsets = [located for located in new_tests if located.item.kind == :testset]
    edited = [
        item.name => string("edited testset (", describe_item(delta.path, item), ")") for delta in test_deltas for
            item in delta.new_hit if item.kind == :testset
    ]
    helper_seeds = Set(
        reduce(
            vcat,
            ([name for name in delta_names(delta)] for delta in test_deltas);
            init = String[],
        ),
    )
    helper_functions = reduce(
        vcat,
        (
            [item.name for item in vcat(delta.old_hit, delta.new_hit) if item.kind == :function] for delta in test_deltas
        );
        init = String[],
    )
    fixtures = [basename(change.path) for (change, class) in zip(changes, classes) if class == :fixture]
    test_binders = [located for located in new_tests if located.item.kind in (:function, :binding, :other)]
    fixture_seeds = Set(
        reduce(
            vcat,
            (binding_keys(binder.item) for binder in test_binders if any(occursin(file, binder.item.text) for file in fixtures));
            init = String[],
        ),
    )
    test_names = name_closure(union(helper_seeds, Set(helper_functions), source_names, Set(widened), fixture_seeds), test_binders)
    use_reasons = [
        located.item.name => "mentions changed `" * first(sort(collect(intersect(located.item.mentions, test_names)))) * "`" for
            located in new_testsets if !isdisjoint(located.item.mentions, test_names)
    ]
    unreached = [
        name for name in widened
            if !any(endswith(last(pair), string("`", name, "` changed")) for pair in dispatch_reasons) &&
            !any(name in located.item.mentions for located in new_testsets)
    ]
    unreached_lines = [string("new or re-signed function `", name, "`: no testset ran a method of it or names it") for name in unreached]
    fixture_reasons = [
        located.item.name => "reads changed fixture `" * file * "`" for located in new_testsets for
            file in fixtures if occursin(file, located.item.text)
    ]
    new_reasons = [
        located.item.name => "new testset, not in the map" for located in new_testsets
            if !haskey(map.testsets, located.item.name)
    ]
    static_helpers = Set(reduce(vcat, (located.item.keys for located in test_binders if static_item(located.item)); init = String[]))
    static_names = name_closure(union(static_helpers, STATIC_MARKERS), test_binders)
    static_reasons = [
        located.item.name => "static analysis: reads or analyses code, a .jl file changed" for located in new_testsets
            if any_jl && (static_item(located.item) || !isdisjoint(located.item.mentions, static_names))
    ]

    every = vcat(run_reasons, dispatch_reasons, mention_reasons, edited, use_reasons, fixture_reasons, new_reasons, static_reasons)
    reasons = [pair for pair in every if first(pair) in runnable]
    weak = sort([name for (name, entry) in map.testsets if entry.status != "ok"])
    notes = [string("map testset `", name, "` has status ", map.testsets[name].status, ": its coverage may be partial") for name in weak]
    return Selection(reasons, String[], vcat(uncovered, unreached_lines), notes)
end

"""
    retest_pattern(names)

A regex selecting exactly the top-level testsets called `names`. ReTest matches a pattern
against a testset's subject, `/name` for a top-level testset and `/name/inner` for one
nested in it, so each name sits between the leading `/` and the end or the next `/`.
"""
function retest_pattern(names::AbstractVector{<:AbstractString})::String
    return string("^/(", join(("\\Q" * name * "\\E" for name in names), '|'), ")(/|\$)")
end

function report(io::IO, map::CoverageMap, selection::Selection, base::AbstractString, target::AbstractString)::Nothing
    names = sort(unique(first.(selection.reasons)))
    println(io, "map commit ", first(map.commit, 12), " (", length(map.testsets), " testsets); diff ", first(base, 12), " -> ", isempty(target) ? "working tree" : first(target, 12))
    for reason in selection.full
        println(io, "FULL SUITE: ", reason)
    end
    for line in selection.uncovered
        println(io, "UNCOVERED: ", line)
    end
    for line in selection.notes
        println(io, "note: ", line)
    end
    println(io, "selected ", length(names), " testsets")
    for name in names
        reasons = unique([reason for (testset, reason) in selection.reasons if testset == name])
        shown = join(first(reasons, 3), "; ")
        println(io, "  ", name, "  <- ", shown, length(reasons) > 3 ? string("; +", length(reasons) - 3, " more") : "")
    end
    return nothing
end

# ---------------------------------------------------------------------------------------
# Map building
# ---------------------------------------------------------------------------------------

function relative_path(root::AbstractString, file::AbstractString)::String
    for prefix in (root, realpath(root))
        if startswith(file, string(prefix, "/"))
            return relpath(file, prefix)
        end
    end
    return ""
end

function is_hit(row::AbstractString)::Bool
    return startswith(row, "DA:") && parse(Int, split(chopprefix(row, "DA:"), ',')[2]) > 0
end

function record_lines(record::AbstractString, root::AbstractString)::Pair{String,Vector{Int}}
    rows = split(record, '\n')
    files = [chopprefix(row, "SF:") for row in rows if startswith(row, "SF:")]
    if isempty(files)
        return "" => Int[]
    end
    hit = [parse(Int, first(split(chopprefix(row, "DA:"), ','))) for row in rows if is_hit(row)]
    return relative_path(root, String(first(files))) => hit
end

"""
    lcov_files(text, root, sources)

The executed lines of every file under one of the `sources` directories of `root`, from an
LCOV tracefile.
"""
function lcov_files(
        text::AbstractString,
        root::AbstractString,
        sources::AbstractVector{<:AbstractString},
    )::Dict{String,Vector{Int}}
    records = [record_lines(record, root) for record in split(text, "end_of_record")]
    return Dict(
        file => lines for (file, lines) in records
            if !isempty(lines) && any(startswith(file, string(dir, "/")) for dir in sources)
    )
end

"Polls a child process; `timedwait` stops when it returns true."
struct Exited
    process::Base.Process
end

(exited::Exited)()::Bool = !Base.process_running(exited.process)

"""
One testset's coverage run: a fresh Julia process running `runner` on the testset's name
with an LCOV tracefile of its own, counting lines only under `covered` (an `@path`
selector, so dependencies keep their package images). Julia 1.13 matches the selector
against real paths: a path through a symlink counts nothing.
"""
struct Worker
    root::String
    runner::String
    logs::String
    timeout::Int
    sources::Vector{String}
    covered::String
    environment::Vector{Pair{String,String}}
    spans::Dict{String,Vector{UnitRange{Int}}}
end

"""
    executes(sorted, span)

Whether any of the sorted line numbers falls in `span`.
"""
function executes(sorted::AbstractVector{Int}, span::UnitRange{Int})::Bool
    position = searchsortedfirst(sorted, first(span))
    return position <= length(sorted) && sorted[position] <= last(span)
end

"""
    executed_positions(lines, spans)

The positions (as `ranges_text` writes them) of the `spans`, a file's functions in file
order, that contain an executed line.
"""
function executed_positions(lines::AbstractVector{Int}, spans::AbstractVector{UnitRange{Int}})::String
    sorted = sort(lines)
    return ranges_text([position for (position, span) in enumerate(spans) if executes(sorted, span)])
end

"The functions of a source file, in file order."
function file_functions(snapshot::Snapshot, path::AbstractString)::Vector{Item}
    return [item for item in items_at(snapshot, path, true) if item.kind == :function]
end

function (worker::Worker)(name::AbstractString)::Pair{String,Dict{String,Any}}
    stem = first(bytes2hex(SHA.sha1(name)), 12)
    info = joinpath(worker.logs, stem * ".info")
    log = joinpath(worker.logs, stem * ".log")
    rm(info; force = true)
    # `environment` (for ReTest-style runners, a variable that keeps the testset in this
    # coverage-flagged process: distributed workers would start without the coverage flags).
    command = addenv(
        Cmd(
            `$(Base.julia_cmd()) --project=$(worker.root) --startup-file=no --threads=2 --code-coverage=@$(worker.covered) --code-coverage=$info $(joinpath(worker.root, worker.runner)) $(retest_pattern([name]))`;
            dir = worker.root,
        ),
        worker.environment...,
    )
    started = time_ns()
    process = run(pipeline(command; stdout = log, stderr = log); wait = false)
    outcome = timedwait(Exited(process), worker.timeout)
    if outcome == :timed_out
        kill(process, Base.SIGINT)
        if timedwait(Exited(process), 120) == :timed_out
            kill(process, Base.SIGKILL)
        end
    end
    wait(process)
    milliseconds = div(Int(time_ns() - started), 1_000_000)
    lines = Dict{String,Vector{Int}}()
    if isfile(info)
        lines = lcov_files(read(info, String), worker.root, worker.sources)
    end
    rm(info; force = true)
    status = "failed"
    if success(process)
        status = "ok"
    end
    if outcome == :timed_out
        status = "timeout"
    end
    if status == "ok" && isempty(lines)
        status = "no-coverage"
    end
    println(stderr, "[TestImpactAnalysis] ", status, " ", milliseconds, " ms  ", name)
    return String(name) => Dict{String,Any}(
        "status" => status,
        "ms" => milliseconds,
        "functions" => Dict{String,Any}(
            file => executed_positions(covered, get(worker.spans, file, UnitRange{Int}[])) for (file, covered) in lines
        ),
    )
end

function jl_files(root::AbstractString, dir::AbstractString)::Vector{String}
    found = [
        relpath(joinpath(folder, file), root) for (folder, _, files) in walkdir(joinpath(root, dir))
            for file in files if endswith(file, ".jl")
    ]
    return sort(found)
end

"""
    build_map(root, out; tests, sources, runner, jobs, timeout, only, shard, shards, commit, environment)

Run every top-level testset of `tests` (found statically, following literal includes) in its
own process and write the map to `out`. Testsets are ordered by source length and dealt
round-robin into `shards` shards; this call runs shard `shard` (`merge` joins the shards'
maps). The shard's smallest testset runs alone first, so the coverage-flagged
precompilation finishes before the rest start together. The map lists the functions of every
`.jl` file under `sources` (as parsed in `root`) and records, per testset, which ran.
"""
function build_map(
        root::AbstractString,
        out::AbstractString;
        tests::AbstractString,
        sources::AbstractVector{<:AbstractString},
        runner::AbstractString,
        jobs::Integer,
        timeout::Integer,
        only::AbstractVector{<:AbstractString},
        shard::Integer,
        shards::Integer,
        commit::AbstractString,
        environment::AbstractVector{Pair{String,String}},
    )::Nothing
    located = located_items(Snapshot(String(root), ""), tests)
    testsets = [entry for entry in located if entry.item.kind == :testset]
    dynamic = [describe_item(entry.path, entry.item) for entry in testsets if isempty(entry.item.name)]
    if !isempty(dynamic)
        error("testsets with a computed name cannot be selected by name: ", join(dynamic, ", "))
    end
    hidden = [describe_item(entry.path, entry.item) for entry in located if entry.item.kind == :other && occursin("@testset", entry.item.text)]
    for place in hidden
        println(stderr, "[TestImpactAnalysis] warning: testsets inside control flow are not mapped: ", place)
    end
    spans = Dict(name => sum(entry.item.last - entry.item.first for entry in testsets if entry.item.name == name) for name in unique([entry.item.name for entry in testsets]))
    names = first.(sort(collect(spans); by = last))
    names = [name for name in names if isempty(only) || any(occursin(part, name) for part in only)][shard:shards:end]
    if isempty(names)
        error("no testset matches --only ", join(only, ", "), " in shard ", shard, "/", shards)
    end
    logs = string(out, ".work")
    mkpath(logs)
    covered = realpath(joinpath(root, length(sources) == 1 ? first(sources) : ""))
    snapshot = Snapshot(String(root), "")
    paths = reduce(vcat, (jl_files(root, dir) for dir in sources); init = String[])
    functions = Dict(path => file_functions(snapshot, path) for path in paths)
    definitions = Dict(path => String[item.header for item in items] for (path, items) in functions)
    line_spans = Dict(path => UnitRange{Int}[item.first:item.last for item in items] for (path, items) in functions)
    worker = Worker(String(root), String(runner), logs, timeout, String[sources...], covered, environment, line_spans)
    results = vcat([worker(first(names))], asyncmap(worker, reverse(names[2:end]); ntasks = jobs))
    document = Dict{String,Any}(
        "meta" => Dict{String,Any}(
            "commit" => commit,
            "built" => string(Dates.now()),
            "julia" => string(VERSION),
            "tests" => String(tests),
            "runner" => String(runner),
            "sources" => String[sources...],
        ),
        "definitions" => definitions,
        "testsets" => Dict{String,Any}(results),
    )
    buffer = IOBuffer()
    TOML.print(buffer, document; sorted = true)
    write(out, take!(buffer))
    unhealthy = [name => result["status"] for (name, result) in results if result["status"] != "ok"]
    println(stderr, "[TestImpactAnalysis] wrote ", out, ": ", length(results), " testsets, ", length(unhealthy), " not ok")
    for (name, status) in unhealthy
        println(stderr, "[TestImpactAnalysis]   ", status, "  ", name)
    end
    return nothing
end

"""
    merge_maps(out, inputs)

Join the maps of a sharded build into one. Every shard must come from the same commit and
list the same definitions; a testset mapped twice is an error.
"""
function merge_maps(out::AbstractString, inputs::AbstractVector{<:AbstractString})::Nothing
    documents = [TOML.parsefile(input) for input in inputs]
    reference = first(documents)
    for (input, document) in zip(inputs, documents)
        same_meta = all(document["meta"][key] == reference["meta"][key] for key in ("commit", "tests", "runner", "sources"))
        if !same_meta || document["definitions"] != reference["definitions"]
            error(input, " was built from another commit or other files than ", first(inputs))
        end
    end
    names = reduce(vcat, (collect(keys(document["testsets"])) for document in documents); init = String[])
    if !allunique(names)
        error("testsets mapped by more than one shard: ", join(unique(name for name in names if count(==(name), names) > 1), ", "))
    end
    merged = Dict{String,Any}(
        "meta" => reference["meta"],
        "definitions" => reference["definitions"],
        "testsets" => merge((document["testsets"] for document in documents)...),
    )
    buffer = IOBuffer()
    TOML.print(buffer, merged; sorted = true)
    write(out, take!(buffer))
    println(stderr, "[TestImpactAnalysis] merged ", length(inputs), " maps into ", out, ": ", length(names), " testsets")
    return nothing
end

# ---------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------

function option_values(args::AbstractVector{<:AbstractString}, flag::AbstractString)::Vector{String}
    positions = findall(==(flag), args)
    if any(position == lastindex(args) for position in positions)
        error(flag, " needs a value")
    end
    return [String(args[position + 1]) for position in positions]
end

function option_value(args::AbstractVector{<:AbstractString}, flag::AbstractString, fallback::AbstractString)::String
    values = option_values(args, flag)
    if isempty(values)
        return String(fallback)
    end
    return last(values)
end

const USAGE = """
usage: testimpact.jl COMMAND [options]
  build   [--map MAP] [--root DIR] [--tests test/runtests.jl] [--source src]...
          [--runner test/runtests.jl] [--jobs N] [--timeout SECONDS] [--only SUBSTRING]...
          [--shard K/N] [--commit REV] [--env NAME=VALUE]...
  merge   [--map MAP] --in SHARD_MAP --in SHARD_MAP ...
  select  [--map MAP] [--root DIR] [--base REV] [--to REV]
  run     the options of select; runs the selected testsets through the map's runner
--root defaults to the current directory and MAP to ROOT/test-impact-map.toml.
"""

"""
    main(args)

Run the `build`, `merge`, `select` or `run` command. Every failure (a file that does not parse,
a map that does not match the files) is an uncaught error, so the process exits nonzero with it.
"""
function main(args::AbstractVector{<:AbstractString})::Nothing
    root = abspath(option_value(args, "--root", pwd()))
    map_path = abspath(root, option_value(args, "--map", "test-impact-map.toml"))
    command = ""
    if !isempty(args)
        command = first(args)
    end
    if command == "build"
        sources = option_values(args, "--source")
        if isempty(sources)
            sources = ["src"]
        end
        shard = parse.(Int, split(option_value(args, "--shard", "1/1"), '/'))
        build_map(
            root,
            map_path;
            tests = option_value(args, "--tests", "test/runtests.jl"),
            sources = sources,
            runner = option_value(args, "--runner", "test/runtests.jl"),
            jobs = parse(Int, option_value(args, "--jobs", string(max(1, Sys.CPU_THREADS)))),
            timeout = parse(Int, option_value(args, "--timeout", "3600")),
            only = option_values(args, "--only"),
            shard = first(shard),
            shards = last(shard),
            commit = option_value(args, "--commit", strip(git(root, "rev-parse", "HEAD"))),
            environment = [String(first(pair)) => String(last(pair)) for pair in split.(option_values(args, "--env"), '='; limit = 2)],
        )
        return nothing
    end
    if command == "merge"
        merge_maps(map_path, option_values(args, "--in"))
        return nothing
    end
    if command in ("select", "run")
        select_command(root, map_path, args, command == "run")
        return nothing
    end
    error(USAGE)
end

function select_command(
        root::AbstractString,
        map_path::AbstractString,
        args::AbstractVector{<:AbstractString},
        run_selected::Bool,
    )::Nothing
    map = read_map(map_path)
    base = strip(git(root, "rev-parse", "--verify", map.commit * "^{commit}"))
    base = option_value(args, "--base", base)
    target = option_value(args, "--to", "")
    if isempty(target)
        toplevel = realpath(strip(git(root, "rev-parse", "--show-toplevel")))
        if toplevel != realpath(root)
            error("--root ", root, " is not a git checkout of its own (git sees ", toplevel, "); pass --to REV to compare two revisions")
        end
    else
        target = strip(git(root, "rev-parse", "--verify", target * "^{commit}"))
    end
    selection = select_testsets(root, map, String(base), String(target))
    report(stdout, map, selection, base, target)
    names = sort(unique(first.(selection.reasons)))
    pattern = retest_pattern(names)
    println("pattern: ", pattern)
    println("run: julia --project=. ", map.runner, " '", pattern, "'")
    if run_selected && !isempty(names)
        run(Cmd(`$(Base.julia_cmd()) --project=$root $(joinpath(root, map.runner)) $pattern`; dir = root))
    end
    return nothing
end

end # module
