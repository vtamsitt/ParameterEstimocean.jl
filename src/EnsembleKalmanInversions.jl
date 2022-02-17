module EnsembleKalmanInversions

export
    iterate!,
    EnsembleKalmanInversion,
    Resampler,
    FullEnsembleDistribution,
    SuccessfulEnsembleDistribution

using OffsetArrays
using ProgressBars
using Random
using Printf
using LinearAlgebra
using Suppressor: @suppress
using Statistics
using Distributions
using EnsembleKalmanProcesses.EnsembleKalmanProcessModule
using EnsembleKalmanProcesses.ParameterDistributionStorage

using EnsembleKalmanProcesses.EnsembleKalmanProcessModule: sample_distribution

using ..Parameters: unconstrained_prior, transform_to_constrained, inverse_covariance_transform
using ..InverseProblems: Nensemble, observation_map, forward_map, tupify_parameters

mutable struct EnsembleKalmanInversion{I, E, M, O, F, S, R, X, G}
    inverse_problem :: I
    ensemble_kalman_process :: E
    mapped_observations :: M
    noise_covariance :: O
    inverting_forward_map :: F
    iteration :: Int
    iteration_summaries :: S
    resampler :: R
    unconstrained_parameters :: X
    forward_map_output :: G
end

Base.show(io::IO, eki::EnsembleKalmanInversion) =
    print(io, "EnsembleKalmanInversion", '\n',
              "├── inverse_problem: ", summary(eki.inverse_problem), '\n',
              "├── ensemble_kalman_process: ", summary(eki.ensemble_kalman_process), '\n',
              "├── mapped_observations: ", summary(eki.mapped_observations), '\n',
              "├── noise_covariance: ", summary(eki.noise_covariance), '\n',
              "├── iteration: $(eki.iteration)", '\n',
              "├── resampler: $(summary(eki.resampler))",
              "├── unconstrained_parameters: $(summary(eki.unconstrained_parameters))", '\n',
              "└── forward_map_output: $(summary(eki.forward_map_output))")

construct_noise_covariance(noise_covariance::AbstractMatrix, y) = noise_covariance

function construct_noise_covariance(noise_covariance::Number, y)
    Nobs = length(y)
    return Matrix(noise_covariance * I, Nobs, Nobs)
end
    
"""
    EnsembleKalmanInversion(inverse_problem; noise_covariance=1e-2, resampler=Resampler())

Return an object that interfaces with
[EnsembleKalmanProcesses.jl](https://github.com/CliMA/EnsembleKalmanProcesses.jl)
and uses Ensemble Kalman Inversion to iteratively "solve" the inverse problem:

```math
y = G(θ) + η,
```

for the parameters ``θ``, where ``y`` is a "normalized" vector of observations,
``G(θ)`` is a forward map that predicts the observations, and ``η ∼ 𝒩(0, Γ_y)`` is zero-mean
random noise with covariance matrix ``Γ_y`` representing uncertainty in the observations.

By "solve", we mean that the iteration finds the parameter values ``θ`` that minimizes the
distance between ``y`` and ``G(θ)``.

The "forward map output" `G` can have many interpretations. The specific statistics that `G` computes
have to be selected for each use case to provide a concise summary of the complex model solution that
contains the values that we would most like to match to the corresponding truth values `y`. For example,
in the context of an ocean-surface boundary layer parametrization, this summary could be a vector of 
concatenated `u`, `v`, `b`, `e` profiles at all or some time steps of the CATKE solution.

(For more details on the Ensemble Kalman Inversion algorithm refer to the
[EnsembleKalmanProcesses.jl Documentation](https://clima.github.io/EnsembleKalmanProcesses.jl/stable/ensemble_kalman_inversion/).)

Arguments
=========

- `inverse_problem :: InverseProblem`: Represents an inverse problem representing the comparison between
                                       synthetic observations generated by
                                       [Oceananigans.jl](https://clima.github.io/OceananigansDocumentation/stable/)
                                       and model predictions, also generated by Oceananigans.jl.

- `noise_covariance` (`AbstractMatrix` or `Number`): normalized covariance representing observational
                                                     uncertainty. If `noise_covariance isa Number` then
                                                     it's converted to an identity matrix scaled by
                                                     `noise_covariance`.

- `resampler`: controls particle resampling procedure. See `Resampler`.
"""
function EnsembleKalmanInversion(inverse_problem;
                                 noise_covariance = 1e-2,
                                 resampler = Resampler(),
                                 unconstrained_parameters = nothing,
                                 iteration_summaries = nothing,
                                 forward_map_output)

    free_parameters = inverse_problem.free_parameters
    priors = free_parameters.priors

    # The closure G(θ) maps (Nθ, Nensemble) array to (Noutput, Nensemble)
    function inverting_forward_map(X::AbstractMatrix)
        Nensemble = size(X, 2)

        # Compute inverse transform from unconstrained (transformed) space to
        # constrained (physical) space
        θ = transform_to_constrained(priors, X)

        return forward_map(inverse_problem, θ)
    end

    Nθ = length(priors)
    Nens = Nensemble(inverse_problem)

    # Generate an initial sample of parameters
    unconstrained_priors = NamedTuple(name => unconstrained_prior(priors[name]) for name in free_parameters.names)

    if isnothing(unconstrained_parameters)
        Xᵢ = [rand(unconstrained_priors[i]) for i=1:Nθ, k=1:Nens]
    else
        Xᵢ = unconstrained_parameters
    end

    # Build EKP-friendly observations "y" and the covariance matrix of observational uncertainty "Γy"
    y = dropdims(observation_map(inverse_problem), dims=2) # length(forward_map_output) column vector
    Γy = construct_noise_covariance(noise_covariance, y)

    ensemble_kalman_process = EnsembleKalmanProcess(Xᵢ, y, Γy, Inversion())
    iteration = 0

    eki′ = EnsembleKalmanInversion(inverse_problem,
                                   ensemble_kalman_process,
                                   y,
                                   Γy,
                                   inverting_forward_map,
                                   iteration,
                                   nothing,
                                   resampler,
                                   Xᵢ,
                                   nothing)

    if isnothing(forward_map_output)
        # Rebuild eki with the summary and forward map (and potentially
        # resampled parameters) for iteration 0:
        forward_map_output, summary = forward_map_and_summary(eki′)
    else # output was provided, so avoid a forward run:
        summary = IterationSummary(eki′, Xᵢ, forward_map_output)
    end

    iteration_summaries = OffsetArray([summary], -1)

    eki = EnsembleKalmanInversion(inverse_problem,
                                  eki′.ensemble_kalman_process,
                                  eki′.mapped_observations,
                                  eki′.noise_covariance,
                                  eki′.inverting_forward_map,
                                  iteration,
                                  iteration_summaries,
                                  eki′.resampler,
                                  eki′.unconstrained_parameters,
                                  forward_map_output)

    return eki
end

struct IterationSummary{P, M, C, V, E}
    parameters :: P     # constrained
    ensemble_mean :: M  # constrained
    ensemble_cov :: C   # constrained
    ensemble_var :: V
    mean_square_errors :: E
    iteration :: Int
end

"""
    IterationSummary(eki, X, forward_map_output=nothing)

Return the summary for ensemble Kalman inversion `eki`
with unconstrained parameters `X` and `forward_map_output`.
"""
function IterationSummary(eki, X, forward_map_output=nothing)
    priors = eki.inverse_problem.free_parameters.priors

    ensemble_mean = mean(X, dims=2)[:] 
    constrained_ensemble_mean = transform_to_constrained(priors, ensemble_mean)

    ensemble_covariance = cov(X, dims=2)
    constrained_ensemble_covariance = inverse_covariance_transform(values(priors), X, ensemble_covariance)
    constrained_ensemble_variance = tupify_parameters(eki.inverse_problem, diag(constrained_ensemble_covariance))

    constrained_parameters = transform_to_constrained(priors, X)

    if !isnothing(forward_map_output)
        Nobs, Nens= size(forward_map_output)
        y = eki.mapped_observations
        G = forward_map_output
        mean_square_errors = [mapreduce((x, y) -> (x - y)^2, +, y, view(G, :, k)) / Nobs for k = 1:Nens]
    else
        mean_square_errors = nothing
    end

    return IterationSummary(constrained_parameters,
                            constrained_ensemble_mean,
                            constrained_ensemble_covariance,
                            constrained_ensemble_variance,
                            mean_square_errors,
                            eki.iteration)
end

function Base.show(io::IO, is::IterationSummary)

    max_error, imax = findmax(is.mean_square_errors)
    min_error, imin = findmin(is.mean_square_errors)

    names = keys(is.ensemble_mean)
    parameter_matrix = [is.parameters[k][name] for name in names, k = 1:length(is.parameters)]
    min_parameters = minimum(parameter_matrix, dims=2)
    max_parameters = maximum(parameter_matrix, dims=2)

    print(io, summary(is), '\n')

    print(io, "                      ", param_str.(keys(is.ensemble_mean))..., '\n',
              "       ensemble_mean: ", param_str.(values(is.ensemble_mean))..., '\n',
              particle_str("best", is.mean_square_errors[imin], is.parameters[imin]), '\n',
              particle_str("worst", is.mean_square_errors[imax], is.parameters[imax]), '\n',
              "             minimum: ", param_str.(min_parameters)..., '\n',
              "             maximum: ", param_str.(max_parameters)..., '\n',
              "   ensemble_variance: ", param_str.(values(is.ensemble_var))...)

    return nothing
end

Base.summary(is::IterationSummary) = string("IterationSummary for ", length(is.parameters),
                                            " particles and ", length(keys(is.ensemble_mean)),
                                            " parameters at iteration ", is.iteration)

function param_str(p::Symbol)
    p_str = string(p)
    length(p_str) > 9 && (p_str = p_str[1:9])
    return @sprintf("% 10s | ", p_str)
end

param_str(p::Number) = @sprintf("% -1.3e | ", p)

particle_str(particle, error, parameters) =
    @sprintf("% 11s particle: ", particle) *
    string(param_str.(values(parameters))...) *
    @sprintf("error = %.6e", error)

"""
    sample(eki, θ, G, Nsample)

Generate `Nsample` new particles sampled from a multivariate Normal distribution parameterized 
by the ensemble mean and covariance computed based on the `Nθ` × `Nensemble` ensemble 
array `θ`, under the condition that all `Nsample` particles produce successful forward map
outputs (don't include `NaNs`).

`G` (`size(G) =  Noutput × Nensemble`) is the forward map output produced by `θ`.

Returns `Nθ × Nsample` parameter `Array` and `Noutput × Nsample` forward map output `Array`.
"""
function sample(eki, θ, G, Nsample)
    Nθ, Nensemble = size(θ)
    Noutput = size(G, 1)

    Nfound = 0
    found_X = zeros(Nθ, 0)
    found_G = zeros(Noutput, 0)
    existing_sample_distribution = eki.resampler.distribution(θ, G)

    while Nfound < Nsample
        @info "Re-sampling ensemble members (found $Nfound of $Nsample)..."

        # Generate `Nensemble` new samples in unconstrained space.
        # Note that eki.inverse_problem.simulation
        # must run `Nensemble` particles no matter what.
        X_sample = rand(existing_sample_distribution, Nensemble)
        G_sample = eki.inverting_forward_map(X_sample)

        nan_values = column_has_nan(G_sample)
        success_columns = findall(.!column_has_nan(G_sample))
        @info "    ... found $(length(success_columns)) successful particles."

        found_X = cat(found_X, X_sample[:, success_columns], dims=2)
        found_G = cat(found_G, G_sample[:, success_columns], dims=2)
        Nfound = size(found_X, 2)
    end

    # Restrict found particles to requested size
    return found_X[:, 1:Nsample], found_G[:, 1:Nsample]
end

function forward_map_and_summary(eki, X=eki.unconstrained_parameters)
    G = eki.forward_map_output = eki.inverting_forward_map(X)             # (len(G), Nensemble)
    resample!(eki.resampler, X, G, eki)
    return G, IterationSummary(eki, X, G)
end

"""
    iterate!(eki::EnsembleKalmanInversion; iterations = 1, show_progress = true)

Iterate the ensemble Kalman inversion problem `eki` forward by `iterations`.

Return
======

- `best_parameters`: the ensemble mean of all parameter values after the last iteration.
"""
function iterate!(eki::EnsembleKalmanInversion; iterations = 1, show_progress = true)

    iterator = show_progress ? ProgressBar(1:iterations) : 1:iterations

    for _ in iterator
        # Ensemble update
        update_ensemble!(eki.ensemble_kalman_process, eki.forward_map_output)
        X = get_u_final(eki.ensemble_kalman_process)
        eki.unconstrained_parameters .= X
        eki.iteration += 1

        # Forward map
        G, summary = forward_map_and_summary(eki) 
        eki.forward_map_output = G
        push!(eki.iteration_summaries, summary)
    end

    # Return ensemble mean (best guess for optimal parameters)
    best_parameters = eki.iteration_summaries[end].ensemble_mean

    return best_parameters
end

#####
##### Resampling
#####

abstract type EnsembleDistribution end

function ensemble_normal_distribution(θ)
    μ = [mean(θ, dims=2)...]
    Σ = cov(θ, dims=2)
    return MvNormal(μ, Σ)
end

struct FullEnsembleDistribution <: EnsembleDistribution end
(::FullEnsembleDistribution)(θ, G) = ensemble_normal_distribution(θ)

struct SuccessfulEnsembleDistribution <: EnsembleDistribution end
(::SuccessfulEnsembleDistribution)(θ, G) = ensemble_normal_distribution(θ[:, findall(.!column_has_nan(G))])

resample!(::Nothing, args...) = nothing

struct Resampler{D}
    only_failed_particles :: Bool
    acceptable_failure_fraction :: Float64
    distribution :: D
end

function Resampler(; only_failed_particles = true,
                     acceptable_failure_fraction = 0.0,
                     distribution = FullEnsembleDistribution())

    return Resampler(only_failed_particles, acceptable_failure_fraction, distribution)
end

""" Return a BitVector indicating which particles are NaN."""
column_has_nan(G) = vec(mapslices(any, isnan.(G); dims=1))

function failed_particle_str(θ, k, error=nothing)
    first = string(@sprintf(" particle % 3d: ", k), param_str.(values(θ[k]))...)
    error_str = isnothing(error) ? "" : @sprintf(" error = %.6e", error)
    return string(first, error_str, '\n')
end

"""
    resample!(resampler::Resampler, θ, G, eki)
    
Resamples the parameters `θ` of the `eki` process based on the number of `NaN` values
inside the forward map output `G`.
"""
function resample!(resampler::Resampler, X, G, eki)
    # `Nensemble` vector of bits indicating, for each ensemble member, whether the forward map contained `NaN`s
    nan_values = column_has_nan(G)
    nan_columns = findall(nan_values) # indices of columns (particles) with `NaN`s
    nan_count = length(nan_columns)
    nan_fraction = nan_count / size(X, 2)

    if nan_fraction > 0

        # Print a nice message
        particles = nan_count == 1 ? "particle" : "particles"

        priors = eki.inverse_problem.free_parameters.priors
        θ = transform_to_constrained(priors, X)
        failed_parameters_message = string("               ",  param_str.(keys(priors))..., '\n',
                                           (failed_particle_str(θ, k) for k in nan_columns)...)

        @warn("""
              The forward map for $nan_count $particles ($(100nan_fraction)%) included NaNs.
              The failed particles are:
              $failed_parameters_message
              """)
    end

    too_much_failure = false

    if nan_fraction > resampler.acceptable_failure_fraction
        error("The forward map for $nan_count particles ($(100nan_fraction)%) included NaNs. Consider \n" *
              "    1. Increasing `Resampler.acceptable_failure_fraction` for \n" *
              "         EnsembleKalmanInversion.resampler::Resampler \n" * 
              "    2. Reducing the time-step for `InverseProblem.simulation`, \n" *
              "    3. Evolving `InverseProblem.simulation` for less time \n" *
              "    4. Narrowing `FreeParameters` priors.")

        too_much_failure = true
    
    elseif nan_count > 0 || !(resampler.only_failed_particles)
        # We are resampling!

        if resampler.only_failed_particles
            Nsample = nan_count
            replace_columns = nan_columns

        else # resample everything
            Nsample = size(G, 2)
            replace_columns = Colon()
        end

        found_X, found_G = sample(eki, X, G, Nsample)
        
        view(X, :, replace_columns) .= found_X
        view(G, :, replace_columns) .= found_G

        new_process = EnsembleKalmanProcess(X,
                                            eki.mapped_observations,
                                            eki.noise_covariance,
                                            eki.ensemble_kalman_process.process)

        eki.ensemble_kalman_process = new_process

        # Sanity...
        if resampler.only_failed_particles # print a helpful message about the failure replacements
            Nobs, Nensemble = size(G)
            y = eki.mapped_observations
            errors = [mapreduce((x, y) -> (x - y)^2, +, y, view(G, :, k)) / Nobs for k in nan_columns]

            priors = eki.inverse_problem.free_parameters.priors
            new_θ = transform_to_constrained(priors, X)

            particle_strings = [failed_particle_str(new_θ, k, errors[i]) for (i, k) in enumerate(nan_columns)]
            failed_parameters_message = string("               ",  param_str.(keys(priors))..., '\n',
                                               particle_strings...)

            @info """
            The replacements for failed particles are
            $failed_parameters_message
            """
        end
    end

    return too_much_failure
end

end # module
