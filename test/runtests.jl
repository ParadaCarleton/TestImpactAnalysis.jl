# Self-check of the selector on a throwaway git repository with a hand-written map:
#     julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'   (from the package's directory)
using Test
using TestImpactAnalysis: TestImpactAnalysis, executed_positions, lcov_files, merge_maps, parse_ranges, ranges_text, read_map, retest_pattern, runner_arguments, select_testsets

const PACKAGE = """
module P
"A thing."
struct S
    a::Int
end
f(x) = x + 1
function g(x::Int)
    return 2x
end
h(s::S) = s.a
unused(x) = x
end
"""

const TESTS = """
using Test
helper() = 1
@testset "runs f" begin
    @test P.f(1) == 2
end
@testset "runs g" begin
    @test P.g(1) == 2
end
@testset "uses S" begin
    @test P.h(P.S(1)) == 1
end
@testset "helper user" begin
    @test helper() == 1
end
"""

function git_run(root::AbstractString, args::AbstractString...)::String
    command = `git -C $root -c user.name=check -c user.email=check@example.com $(collect(args))`
    return read(command, String)
end

function write_file(root::AbstractString, path::AbstractString, text::AbstractString)::Nothing
    mkpath(dirname(joinpath(root, path)))
    write(joinpath(root, path), text)
    return nothing
end

"A repository holding the package and its tests at one commit, and a map built from it."
function fixture(root::AbstractString)::String
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\n")
    write_file(root, "src/P.jl", PACKAGE)
    write_file(root, "test/runtests.jl", TESTS)
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "base")
    commit = strip(git_run(root, "rev-parse", "HEAD"))
    map = """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/retest.jl"
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)", "h(s::S)", "unused(x)"]
    [testsets."runs f"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    [testsets."runs g"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "2" }
    [testsets."uses S"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "3" }
    [testsets."helper user"]
    status = "ok"
    ms = 1
    functions = {}
    """
    write_file(root, "map.toml", map)
    write_file(root, ".gitignore", "map.toml\n.gitignore\n")
    return commit
end

"The selection after replacing `old` by `new` in `path` (working tree, not committed)."
function selected_after(root::AbstractString, path::AbstractString, old::AbstractString, new::AbstractString)::TestImpactAnalysis.Selection
    original = read(joinpath(root, path), String)
    @assert occursin(old, original)
    write_file(root, path, replace(original, old => new))
    map = read_map(joinpath(root, "map.toml"))
    try
        return select_testsets(root, map, map.commit, "")
    finally
        write_file(root, path, original)
    end
end

names_in(selection::TestImpactAnalysis.Selection)::Vector{String} = sort(unique(first.(selection.reasons)))

@testset "selector" begin
    root = mktempdir()
    fixture(root)

    @test names_in(selected_after(root, "src/P.jl", "x + 1", "x + 2")) == ["runs f"]
    @test isempty(names_in(selected_after(root, "src/P.jl", "\"A thing.\"", "\"Another thing.\"")))
    @test isempty(names_in(selected_after(root, "src/P.jl", "f(x) = x + 1", "f(x) = x + 1 # note")))

    struct_change = selected_after(root, "src/P.jl", "a::Int", "a::Float32")
    @test names_in(struct_change) == ["uses S"]

    dispatch = selected_after(root, "src/P.jl", "function g(x::Int)", "function g(x::Integer)")
    @test names_in(dispatch) == ["runs g"]
    @test any(occursin("dispatch", last(pair)) for pair in dispatch.reasons)

    unused_change = selected_after(root, "src/P.jl", "unused(x) = x", "unused(x) = 2x")
    @test isempty(names_in(unused_change))
    @test length(unused_change.uncovered) == 1

    @test names_in(selected_after(root, "test/runtests.jl", "P.g(1) == 2", "P.g(2) == 4")) == ["runs g"]
    @test names_in(selected_after(root, "test/runtests.jl", "helper() = 1", "helper() = 2")) == ["helper user"]

    full = selected_after(root, "Project.toml", "name = \"P\"", "name = \"P\"\nversion = \"0.1.0\"")
    @test names_in(full) == ["helper user", "runs f", "runs g", "uses S"]
    @test !isempty(full.full)

    @test_throws "cannot parse" selected_after(root, "src/P.jl", "x + 1", "x + )")
end

@testset "an import changes the names it stops importing, not the ones it starts importing" begin
    root = mktempdir()
    commit = fixture(root)
    # `h` mentions `S`: an import of `S` reaches it only by dropping the name.
    @test isempty(names_in(selected_after(root, "src/P.jl", "module P\n", "module P\nusing Q: S\n")))

    write_file(root, "src/P.jl", replace(PACKAGE, "module P\n" => "module P\nusing Q: S\n"))
    git_run(root, "commit", "-q", "-am", "import S")
    imported = strip(git_run(root, "rev-parse", "HEAD"))
    write_file(root, "map.toml", replace(read(joinpath(root, "map.toml"), String), commit => imported))
    @test names_in(selected_after(root, "src/P.jl", "using Q: S\n", "")) == ["uses S"]
    @test isempty(names_in(selected_after(root, "src/P.jl", "using Q: S\n", "using Q: S, T\n")))
end

@testset "pattern and coverage records" begin
    pattern = Regex(retest_pattern(["a (b)", "c.d"]))
    @test occursin(pattern, "/a (b)")
    @test occursin(pattern, "/a (b)/inner")
    @test occursin(pattern, "/c.d")
    @test !occursin(pattern, "/a (b) more")
    @test !occursin(pattern, "/cxd")
    @test !occursin(pattern, "/x/a (b)")

    @test ranges_text([9, 1, 2, 3, 5, 9]) == "1-3,5,9"
    @test parse_ranges("1-3,5,9") == [1:3, 5:5, 9:9]

    root = mktempdir()
    tracefile = "SF:$root/src/a.jl\nDA:1,1\nDA:2,0\nDA:3,4\nend_of_record\nSF:/elsewhere/b.jl\nDA:1,1\nend_of_record\n"
    @test lcov_files(tracefile, root, ["src"]) == Dict("src/a.jl" => [1, 3])
    @test executed_positions([6, 8, 9], [6:6, 7:9, 10:10]) == "1-2"
end

function shard_map(commit::AbstractString, testset::AbstractString)::String
    return """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/retest.jl"
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)"]
    [testsets."$testset"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    """
end

@testset "shard merge" begin
    root = mktempdir()
    write(joinpath(root, "one.toml"), shard_map("c0ffee", "runs f"))
    write(joinpath(root, "two.toml"), shard_map("c0ffee", "runs g"))
    write(joinpath(root, "again.toml"), shard_map("c0ffee", "runs g"))
    write(joinpath(root, "other.toml"), shard_map("beef", "uses S"))
    merge_maps(joinpath(root, "map.toml"), [joinpath(root, "one.toml"), joinpath(root, "two.toml")])
    @test sort(collect(keys(read_map(joinpath(root, "map.toml")).testsets))) == ["runs f", "runs g"]
    @test_throws "more than one shard" merge_maps(joinpath(root, "map.toml"), [joinpath(root, "two.toml"), joinpath(root, "again.toml")])
    @test_throws "another commit" merge_maps(joinpath(root, "map.toml"), [joinpath(root, "one.toml"), joinpath(root, "other.toml")])
    @test read_map(joinpath(root, "one.toml")).project == "."
    write(joinpath(root, "nested.toml"), replace(shard_map("c0ffee", "uses S"), "[definitions]" => "project = \"test\"\n[definitions]"))
    @test read_map(joinpath(root, "nested.toml")).project == "test"
    @test_throws "other files" merge_maps(joinpath(root, "map.toml"), [joinpath(root, "one.toml"), joinpath(root, "nested.toml")])
end

@testset "identity survives an unrelated edit above a covered function" begin
    root = mktempdir()
    fixture(root)
    write_file(root, "src/P.jl", replace(PACKAGE, "f(x) = x + 1" => "extra(x) = x\nf(x) = x + 1"))
    git_run(root, "commit", "-q", "-a", "-m", "unrelated edit above f")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    map = read_map(joinpath(root, "map.toml"))
    write_file(root, "src/P.jl", replace(read(joinpath(root, "src/P.jl"), String), "x + 1" => "x + 2"))
    @test names_in(select_testsets(root, map, base, "")) == ["runs f"]
end

@testset "functions the map lacks and functions that moved" begin
    root = mktempdir()
    fixture(root)
    fresh = selected_after(root, "src/P.jl", "unused(x) = x", "unused(x) = x\nfresh(x) = x")
    @test isempty(names_in(fresh))
    @test any(occursin("`fresh`", line) for line in fresh.uncovered)

    write_file(root, "src/P.jl", replace(PACKAGE, "h(s::S) = s.a\n" => "extra(x) = x\n"))
    write_file(root, "src/Q.jl", "h(s::S) = s.a\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "move h to Q.jl, add extra")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    map = read_map(joinpath(root, "map.toml"))

    write_file(root, "src/Q.jl", "h(s::S) = s.a + 1\n")
    @test names_in(select_testsets(root, map, base, "")) == ["uses S"]

    write_file(root, "src/Q.jl", "h(s::S) = s.a\n")
    write_file(root, "src/P.jl", replace(read(joinpath(root, "src/P.jl"), String), "extra(x) = x" => "extra(x) = 2x"))
    lacking = select_testsets(root, map, base, "")
    @test isempty(names_in(lacking))
    @test any(occursin("`extra`", line) for line in lacking.uncovered)
end

"The text `main(args)` prints to stdout."
function printed_by_main(args::AbstractVector{<:AbstractString})::String
    path = tempname()
    open(path, "w") do io
        redirect_stdout(io) do
            TestImpactAnalysis.main(args)
        end
    end
    return read(path, String)
end

@testset "select diffs against the merge-base with the trunk" begin
    root = mktempdir()
    first_commit = fixture(root)
    git_run(root, "branch", "-M", "trunk")
    write_file(root, "src/P.jl", replace(PACKAGE, "f(x) = x + 1" => "extra(x) = x\nf(x) = x + 1"))
    git_run(root, "commit", "-q", "-a", "-m", "trunk moves on")
    git_run(root, "checkout", "-q", "-b", "topic", first_commit)
    write_file(root, "src/P.jl", replace(PACKAGE, "x + 1" => "x + 2"))
    git_run(root, "commit", "-q", "-a", "-m", "topic edits f")
    arguments = ["select", "--root", root, "--map", joinpath(root, "map.toml"), "--trunk", "trunk", "--to", "topic"]

    text = printed_by_main(arguments)
    @test occursin("diff $(first(first_commit, 12)) ->", text)
    @test occursin("selected 1 testsets\n  runs f  <- runs changed `f`", text)
    @test occursin("map lacks 0 of 1 changed functions", text)

    explicit = printed_by_main(vcat(arguments, ["--base", "trunk"]))
    @test occursin("selected 1 testsets", explicit)
    @test occursin("map lacks 1 of 2 changed functions", explicit)
end

@testset "a name is a static-analysis helper only when every definition of it is" begin
    root = mktempdir()
    fixture(root)
    helpers = """
    scan_sources() = readdir("src")
    struct Wrapped
        value::Int
    end
    Wrapped(value::Float64) = error("leak: ", scan_sources())
    """
    write_file(root, "test/helpers.jl", helpers)
    tests = replace(TESTS, "using Test\n" => "using Test\ninclude(\"helpers.jl\")\n") * """
    @testset "scans" begin
        @test !isempty(scan_sources())
    end
    @testset "wraps" begin
        @test Wrapped(1).value == 1
    end
    """
    write_file(root, "test/runtests.jl", tests)
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "helpers")
    base = strip(git_run(root, "rev-parse", "HEAD"))
    write_file(root, "src/P.jl", replace(PACKAGE, "unused(x) = x" => "unused(x) = x # note\nother(x) = x"))
    selection = select_testsets(root, read_map(joinpath(root, "map.toml")), base, "")
    static = sort([first(pair) for pair in selection.reasons if startswith(last(pair), "static analysis")])
    @test static == ["scans"]
end

@testset "macro names are identifiers on every supported Julia" begin
    items = TestImpactAnalysis.source_items("@testset \"t\" begin\n    @check x\nend\n", "macros.jl")
    @test only(items).kind == :testset
    @test "check" in only(items).mentions
end

"A repository whose test files are suites of their own, and a map built from it with `--suites test`."
function suite_fixture(root::AbstractString)::String
    git_run(root, "init", "-q")
    write_file(root, "Project.toml", "name = \"P\"\n")
    write_file(root, "src/P.jl", PACKAGE)
    write_file(root, "test/runtests.jl", "for suite in ARGS\n    include(suite)\nend\n")
    write_file(root, "test/support/helper.jl", "helper() = 1\n")
    write_file(root, "test/a/test_f.jl", "using Test\n@testset \"f\" begin\n    @test P.f(1) == 2\nend\n")
    write_file(root, "test/test_g.jl", "using Test\ninclude(\"support/helper.jl\")\n@testset \"g\" begin\n    @test P.g(helper()) == 2\nend\n")
    git_run(root, "add", "-A")
    git_run(root, "commit", "-q", "-m", "base")
    commit = strip(git_run(root, "rev-parse", "HEAD"))
    map = """
    [meta]
    commit = "$commit"
    tests = "test/runtests.jl"
    runner = "test/runtests.jl"
    suites = "test"
    suite_pattern = '^test_.*\\.jl\$'
    sources = ["src"]
    [definitions]
    "src/P.jl" = ["f(x)", "g(x::Int)", "h(s::S)", "unused(x)"]
    [testsets."a/test_f.jl"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "1" }
    [testsets."test_g.jl"]
    status = "ok"
    ms = 1
    functions = { "src/P.jl" = "2" }
    """
    write_file(root, "map.toml", map)
    write_file(root, ".gitignore", "map.toml\n.gitignore\n")
    return commit
end

@testset "suite files are testsets, run by path" begin
    root = mktempdir()
    suite_fixture(root)
    @test read_map(joinpath(root, "map.toml")).suites == "test"

    @test names_in(selected_after(root, "src/P.jl", "x + 1", "x + 2")) == ["a/test_f.jl"]
    @test names_in(selected_after(root, "src/P.jl", "return 2x", "return 3x")) == ["test_g.jl"]

    edited = selected_after(root, "test/a/test_f.jl", "P.f(1) == 2", "P.f(2) == 3")
    @test names_in(edited) == ["a/test_f.jl"]
    @test any(occursin("edited suite", last(pair)) for pair in edited.reasons)
    @test isempty(names_in(selected_after(root, "test/a/test_f.jl", "using Test\n", "using Test # note\n")))

    @test names_in(selected_after(root, "test/support/helper.jl", "helper() = 1", "helper() = 2")) == ["test_g.jl"]

    write_file(root, "test/test_new.jl", "@testset \"new\" begin\nend\n")
    write_file(root, "test/not_a_suite.jl", "x = 1\n")
    map = read_map(joinpath(root, "map.toml"))
    fresh = select_testsets(root, map, map.commit, "")
    @test names_in(fresh) == ["test_new.jl"]
    rm(joinpath(root, "test/test_new.jl"))
    rm(joinpath(root, "test/not_a_suite.jl"))

    runner = selected_after(root, "test/runtests.jl", "include(suite)", "include(joinpath(@__DIR__, suite))")
    @test names_in(runner) == ["a/test_f.jl", "test_g.jl"]
    @test !isempty(runner.full)

    @test runner_arguments(true, ["a/test_f.jl", "test_g.jl"]) == ["a/test_f.jl", "test_g.jl"]
    @test runner_arguments(false, ["x"]) == [retest_pattern(["x"])]
end

@testset "environment files of the package and the runner's project select the full suite" begin
    dependency_file = TestImpactAnalysis.dependency_file
    @test dependency_file("Project.toml", ["src"], ".")
    @test dependency_file("Manifest-v1.12.toml", ["src"], ".")
    @test dependency_file("pkg/Project.toml", ["pkg/src"], ".")
    @test dependency_file("pkg/test/Project.toml", ["pkg/src"], "pkg/test")
    @test !dependency_file("pkg/docs/Project.toml", ["pkg/src"], "pkg/test")
    @test !dependency_file("pkg/test/Project.toml", ["pkg/src"], ".")
    @test !dependency_file("pkg/src/data.toml", ["pkg/src"], ".")
end
