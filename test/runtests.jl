using StanRun, Test

using StanRun: get_arguments

@testset "cmdstan run and results" begin
    # setup environment
    MODELDIR = mktempdir()
    SAMPLEDIR = mktempdir()
    SRC = joinpath(MODELDIR, "test.stan")
    cp(joinpath(@__DIR__, "test.stan"), SRC)

    # run a model
    model = StanModel(SRC)
    @test repr(model) ==
        "Stan model at $(SRC)\n    (CmdStan home: $(StanRun.get_cmdstan_home()))"
    exec_path = StanRun.ensure_executable(model)
    @test isfile(exec_path)
    n_chains = 5
    OUTPUT_BASE = joinpath(SAMPLEDIR, "test")
    time_before = time()
    @test stan_compile(model) ≡ nothing
    data = (N = 100, x = randn(100))
    chains = stan_sample(model, data, n_chains; output_base = OUTPUT_BASE)
    for (sample, logfile) in chains
        @test ctime(sample) ≥ time_before
        @test ctime(sample) ≥ time_before
    end
    @test first.(chains) == sort(StanRun.find_samples(OUTPUT_BASE)) ==
        [joinpath(SAMPLEDIR, "test_chain_$(i).csv") for i in 1:n_chains]

    @testset "bogus arguments" begin
        chains = stan_sample(model, data, 1;
                             sample_options = (bogus = 12, ))
        # NOTE: if Stan changes it's error message, this may fail
        @test occursin(r"bogus=12.*misplaced", read(chains[1][2], String))
    end
end

@testset "unset cmdstan environment" begin
    withenv("JULIA_CMDSTAN_HOME" => nothing) do
        @test_throws ErrorException StanRun.get_cmdstan_home()
    end
end

@testset "model error and message" begin
    model = StanModel(joinpath(@__DIR__, "test_incorrect.stan"))
    @test_logs (:info, "Stan compilation information") stan_compile(model; debug = true,
                                                                    dry_run = true)
    try
        stan_compile(model)
    catch e
        @test e isa StanRun.StanModelError
        @test occursin("Identifier 'x' not in scope", e.message)
        io = IOBuffer()
        showerror(io, e)
        e_repr = String(take!(io))
        @test occursin("error when compiling", e_repr)
    end
end

@testset "sample options" begin
    expected = [`num_samples=50`, `max_depth=12`]
    @test get_arguments((num_samples = 50, max_depth = 12)) == expected
    @test get_arguments("num_samples=50 max_depth=12") == expected
    @test get_arguments(["num_samples=50", (max_depth=12, )]) == expected
end
