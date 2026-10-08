#!/usr/bin/env julia
# Command line entry, from a clone: julia --startup-file=no bin/testimpact.jl COMMAND ...
include(joinpath(@__DIR__, "..", "src", "TestImpactAnalysis.jl"))
TestImpactAnalysis.main(ARGS)
