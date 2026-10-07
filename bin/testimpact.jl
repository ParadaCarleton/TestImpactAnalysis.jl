#!/usr/bin/env julia
# Command line entry: julia --startup-file=no packages/TestImpactAnalysis/bin/testimpact.jl COMMAND ...
include(joinpath(@__DIR__, "..", "src", "TestImpactAnalysis.jl"))
TestImpactAnalysis.main(ARGS)
