"""
Helper infrastructure to compile and sample models using `cmdstan`.

[`StanModel`](@ref) wraps a model definition (source code), while [`stan_sample`](@ref) can
be used to sample from it.

[`stan_compile`](@ref) can be used to pre-compile a model without sampling, or for
debugging. A [`StanModelError`](@ref) is thrown if this fails, which contains the error
messages from `stanc`.

# Example

```julia
using StanRun
model = StanModel("/path/to/model.stan") # directory should be writable, for compilation
data = (N = 100, x = randn(N, 1000))     # in a format supported by stan_dump
chains = stan_sample(model, data, 5)     # 5 chain paths and log files
```
"""
module StanRun

export StanModel, StanModelError, stan_sample, stan_compile

using ArgCheck: @argcheck
using Distributed: pmap
using DocStringExtensions: FIELDS, SIGNATURES, TYPEDEF
using StanDump: stan_dump

const CMDSTAN_HOME_VAR = "JULIA_CMDSTAN_HOME"

function get_cmdstan_home()
    get(ENV, CMDSTAN_HOME_VAR) do
        throw(ErrorException("The environment variable $CMDSTAN_HOME_VAR needs to be set."))
    end
end

struct StanModel{S <: AbstractString}
    source_path::S
    cmdstan_home::S
end

function Base.show(io::IO, model::StanModel)
    (; source_path, cmdstan_home) = model
    print(io, "Stan model at $(source_path)",
          "\n    (CmdStan home: $(model.cmdstan_home))")
end

"""
$(SIGNATURES)

Replace the extension of `path` (including the `'.'`) with `new_ext`, which can be any
string (not necessarily an extension, with the dot).

When `verified_ext` is given, it the original extension is checked to be equivalent.
Defaults to `".stan"`.

Internal, not exported.
"""
function replace_ext(path::AbstractString, new_ext, verified_ext = ".stan")
    basename, ext = splitext(path)
    verified_ext ≢ nothing && @argcheck ext == verified_ext
    basename * new_ext
end

"""
$(SIGNATURES)

Executable path corresponding to a source file, or a model.

Internal, not exported.
"""
function executable_path(source_path::AbstractString)
    replace_ext(source_path, Sys.iswindows() ? ".exe" : "")
end

executable_path(model::StanModel) = executable_path(model.source_path)

"""
$(SIGNATURES)

Define a model by its Stan source code location, which needs to end in `".stan"`.

Its directory needs to be *writable*, as it will contain the compiled executable (generated
on demand if it does not exist, or if the source code is more recent).

`cmdstan_home` should specify the directory of the `cmdstan` installation. The default is
obtained from the environment variable `$(CMDSTAN_HOME_VAR)`."
"""
function StanModel(source_path; cmdstan_home = get_cmdstan_home())
    if !isabspath(source_path)
        path = abspath(source_path)
        @warn("Stan source path should be an absolute path, replacing",
              original_path = source_path, replacement_path = path)
        source_path = path
    end
    StanModel(source_path, cmdstan_home)
end

"""
$(TYPEDEF)

Error thrown when a Stan model fails to compile. Accessing fields directly is part of the
API.

$(FIELDS)
"""
struct StanModelError <: Exception
    model::StanModel
    message::String
end

function Base.showerror(io::IO, e::StanModelError)
    print(io, "error when compiling ", e.model, ":\n",
          e.message)
end

"""
$(SIGNATURES)

Ensure that a compiled model executable exists, and return its path.

If compilation fails, a `StanModelError` is returned instead.

See [`stan_compile`](@ref) for the documentation of keyword arguments.

Internal, not exported.
"""
function ensure_executable(model::StanModel; debug::Bool = false, dry_run::Bool = false)
    (; cmdstan_home) = model
    exec_path = executable_path(model)
    error_output = IOBuffer()
    info_output = IOBuffer()
    makefile_path = joinpath(cmdstan_home, "makefile")
    cmd = `make $(exec_path)`
    if debug
        @info "Stan compilation information" cmdstan_home cmd exec_path
    end
    if dry_run
        nothing
    else
        is_ok = cd(cmdstan_home) do
            success(pipeline(cmd; stderr = error_output, stdout = info_output))
        end
        if debug
            @info "compilation output" String(take!(info_output))
        end
        if is_ok
            exec_path
        else
            throw(StanModelError(model, String(take!(error_output))))
        end
    end
end

"""
$(SIGNATURES)

Default `output_base`, in the same directory as the model. Internal, not exported.
"""
default_output_base(model::StanModel) = replace_ext(model.source_path, "", ".stan")

sample_file_path(output_base::AbstractString, id::Int) = output_base * "_chain_$(id).csv"

log_file_path(output_base::AbstractString, id::Int) = output_base * "_chain_$(id).log"

"""
$(SIGNATURES)

Make a Stan command. Internal, not exported.
"""
function stan_cmd_and_paths(exec_path::AbstractString, data_file::AbstractString,
                            output_base::AbstractString, id::Integer,
                            sample_options, output_options)
    sample_file = sample_file_path(output_base, id)
    log_file = log_file_path(output_base, id)
    arguments = vcat([`sample`], get_arguments(sample_options),
                     [`id=$(id)`,
                      `data`, `file=$(data_file)`,
                      `output`],
                     get_arguments(output_options),
                     [`file=$(sample_file)`])
    cmd = foldl((x, y) -> `$x $y`, arguments; init = `$(exec_path)`)
    (pipeline(cmd; stdout = log_file, stderr = log_file, append = true),
     (sample_file, log_file))
end

"""
$(SIGNATURES)

Compile a model, throwing an error if it failed.

When `debug = true`, write the command that would be executed into the log.

When `dry_run = true`, don't compile.
"""
function stan_compile(model; debug::Bool = false, dry_run::Bool = false)
    ensure_executable(model; debug = debug, dry_run = dry_run)
    nothing
end

"""
$(SIGNATURES)

Return a `Vector{Cmd}` of arguments that correspond to the given options. See
[`stan_sample`](@ref).
"""
function get_arguments(options::AbstractString)
    map(x -> `$(x)`, split(options, " "; keepempty = false))
end

function get_arguments(options::NamedTuple)
    args = Vector{Cmd}()
    function _append_nt(value::NamedTuple)
        foreach(x -> _append(x...), pairs(value))
    end
    function _append(key, value::NamedTuple)
        push!(args, `$(string(key))`)
       __append_nt(value)
    end
    function _append(key, value::Union{String,Real})
        push!(args, `$(string(key))=$(value)`)
    end
    function _append(key, value::Nothing)
        push!(args, `$(string(key))`)
    end
    _append_nt(options)
    args
end

function get_arguments(options::AbstractVector)
    mapreduce(get_arguments, vcat, options)
end

function stan_sample(model, data::NamedTuple, n_chains::Integer;
                     output_base = default_output_base(model),
                     data_file = output_base * ".data.R",
                     rm_samples = true,
                     sample_options = "",
                     output_options = "",
                     debug_cmds::Bool = false,
                     debug_compilation::Bool = false)
    stan_dump(data_file, data; force = true)
    stan_sample(model, data_file, n_chains;
                output_base, rm_samples, sample_options, output_options, debug_cmds,
                debug_compilation)
end

"""
$(SIGNATURES)

Sample `n_chains` from `model` using `data_file`. Return the full paths of the sample files
and logs as pairs. In case of an error with a chain, the first value is `nothing`.

`output_base` is used to write the data file (using `StanDump.stan_dump`) and to determine
the resulting names for the sampler output. It defaults to the source file name without the
extension.

When `data` is provided as a `NamedTuple`, it is written using `StanDump.stan_dump` first.

When `rm_samples` (default: `true`), remove potential pre-existing sample files after
compiling the model.

`sample_options` and `output_options` are expanded as described below, and passed on to
Stan, pasted in after `sample` or `output`, respectively, in the command line.

When `debug_cmds` (default: `false`), print the shell commands that would be executed with
`@info`.

# Options

Options can be specified either

- A `NamedTuple`, which is expanded recursively (`key = nothing` is expanded to `key`). This
  is the *recommended* approach.

- As a string, which will be split on spaces (**note**: use no spaces around `=`).

- A vector of the above, which can be mixed, which will be concatenated.

For example,

```julia
sample_options = `(num_samples = 500, max_depth = 14)` # recommended
sample_options = "num_samples=500, max_depth=14"       # note: no spaces around =
sample_options = ["num_samples=500", "max_depth=14"]
```

are equivalent.
"""
function stan_sample(model::StanModel, data_file::AbstractString, n_chains::Integer;
                     output_base = default_output_base(model),
                     rm_samples = true,
                     sample_options = "",
                     output_options = "",
                     debug_cmds::Bool = false,
                     debug_compilation::Bool = false)
    exec_path = ensure_executable(model; debug = debug_compilation)
    rm_samples && rm.(find_samples(model))
    cmds_and_paths = [stan_cmd_and_paths(exec_path, data_file, output_base, id,
                                         sample_options, output_options)
                      for id in 1:n_chains]
    if debug_cmds
        @info "stan_sample" first.(cmds_and_paths)
    end
    pmap(cmds_and_paths) do cmd_and_path
        cmd, (sample_path, log_path) = cmd_and_path
        rm(log_path; force = true)
        success(cmd) ? sample_path : nothing, log_path
    end
end

"""
$(SIGNATURES)

Return filenames of CSV files (with MCMC samples, this is not checked) matching
`output_base` from the model.

Part of the API, but not exported.
"""
function find_samples(output_base::AbstractString)
    dir, basename = splitdir(output_base)
    rx = Regex(basename * raw"_chain_\d+.csv")
    joinpath.(Ref(dir), filter(file -> occursin(rx, file), readdir(dir)))
end

find_samples(model::StanModel) = find_samples(default_output_base(model))

end # module
