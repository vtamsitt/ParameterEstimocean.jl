# # Perfect baroclinic adjustment calibration with Ensemble Kalman Inversion
#
# This example showcases a "perfect model calibration" of the two-dimensional baroclinic adjustement
# problem (depth-latitude) with eddies parametrized using Gent-McWilliams--Redi isoneutral diffusion
# closure. We use output for buoyancy (``b``) and a passive-tracer concentration (``c``) to calibrate
# the parametrization.

# ## Install dependencies
#
# First let's make sure we have all required packages installed.

# ```julia
# using Pkg
# pkg"add Oceananigans, Distributions, CairoMakie, OceanTurbulenceParameterEstimation"
# ```

# First we load few things

using OceanTurbulenceParameterEstimation
using Oceananigans
using Oceananigans.Units
using Oceananigans.TurbulenceClosures: FluxTapering
using Oceananigans.Models.HydrostaticFreeSurfaceModels: SliceEnsembleSize
using Distributions
using Printf
using LinearAlgebra: norm

# ## Set up the problem and generate observations

# Define the  "true" skew and symmetric diffusivity coefficients. These are the parameter values that we
# use to generate the data. Then, we'll see if the EKI calibration can recover these values.

κ_skew = 1000.0       # [m² s⁻¹] skew diffusivity
κ_symmetric = 900.0   # [m² s⁻¹] symmetric diffusivity
nothing #hide

# We gather the "true" parameters in a named tuple ``θ_*``:

θ★ = (κ_skew = κ_skew, κ_symmetric = κ_symmetric)

# The experiment name and where the synthetic observations will be saved.
experiment_name = "baroclinic_adjustment"
data_path = experiment_name * ".jld2"

# The domain, number of grid points, and other parameters.
architecture = CPU()      # CPU or GPU?

Ly = 1000kilometers       # north-south extent [m]
Lz = 1kilometers          # depth [m]

Ny = 64                   # grid points in north-south direction
Nz = 16                   # grid points in the vertical

Δt = 10minute             # time-step

stop_time = 1days         # length of run
save_interval = 0.25days  # save observation every so often

generate_observations = true
nothing #hide

# The isopycnal skew-symmetric diffusivity closure.
gerdes_koberle_willebrand_tapering = FluxTapering(1e-2)
gent_mcwilliams_diffusivity = IsopycnalSkewSymmetricDiffusivity(κ_skew = κ_skew,
                                                                κ_symmetric = κ_symmetric,
                                                                slope_limiter = gerdes_koberle_willebrand_tapering)

# ## Generate synthetic observations

if generate_observations || !(isfile(data_path))
    grid = RectilinearGrid(topology = (Flat, Bounded, Bounded), 
                           size = (Ny, Nz), 
                           y = (-Ly/2, Ly/2),
                           z = (-Lz, 0),
                           halo = (3, 3))
    
    model = HydrostaticFreeSurfaceModel(architecture = architecture,
                                        grid = grid,
                                        tracers = (:b, :c),
                                        buoyancy = BuoyancyTracer(),
                                        coriolis = BetaPlane(latitude=-45),
                                        closure = gent_mcwilliams_diffusivity,
                                        free_surface = ImplicitFreeSurface())
    
    @info "Built $model."

    ##### Initial conditions of an unstable buoyancy front

    """
    Linear ramp from 0 to 1 between -Δy/2 and +Δy/2.

    For example:

    y < y₀           => ramp = 0
    y₀ < y < y₀ + Δy => ramp = y / Δy
    y > y₀ + Δy      => ramp = 1
    """
    ramp(y, Δy) = min(max(0, y/Δy + 1/2), 1)

    N² = 4e-6             # [s⁻²] buoyancy frequency / stratification
    M² = 8e-8             # [s⁻²] horizontal buoyancy gradient

    Δy = 50kilometers     # horizontal extent of the font

    Δc_y = 2Δy            # horizontal extent of initial tracer concentration
    Δc_z = 50             # [m] vertical extent of initial tracer concentration

    Δb = Δy * M²          # inital buoyancy jump

    bᵢ(x, y, z) = N² * z + Δb * ramp(y, Δy)
    cᵢ(x, y, z) = exp(-y^2 / 2Δc_y^2) * exp(-(z + Lz/2)^2 / (2Δc_z^2))

    set!(model, b=bᵢ, c=cᵢ)
    
    simulation = Simulation(model, Δt=Δt, stop_time=stop_time)
    
    simulation.output_writers[:fields] = JLD2OutputWriter(model, merge(model.velocities, model.tracers),
                                                          schedule = TimeInterval(save_interval),
                                                          prefix = experiment_name,
                                                          array_type = Array{Float64},
                                                          field_slicer = nothing,
                                                          force = true)

    run!(simulation)
end

# ## Load truth data as observations

observations = OneDimensionalTimeSeries(data_path, field_names=(:b, :c), normalize=ZScore)

# ## Calibration with Ensemble Kalman Inversion

# ### Ensemble model

# First we set up an ensemble model,
ensemble_size = 20

slice_ensemble_size = SliceEnsembleSize(size=(Ny, Nz), ensemble=ensemble_size)
@show ensemble_grid = RectilinearGrid(size=slice_ensemble_size,
                                             topology = (Flat, Bounded, Bounded),
                                             y = (-Ly/2, Ly/2),
                                             z = (-Lz, 0),
                                             halo=(3, 3))

closure_ensemble = [deepcopy(gent_mcwilliams_diffusivity) for i = 1:ensemble_size] 

@show ensemble_model = HydrostaticFreeSurfaceModel(architecture = architecture,
                                                   grid = ensemble_grid,
                                                   tracers = (:b, :c),
                                                   buoyancy = BuoyancyTracer(),
                                                   coriolis = BetaPlane(latitude=-45),
                                                   closure = closure_ensemble,
                                                   free_surface = ImplicitFreeSurface())

# and then we create an ensemble simulation: 

ensemble_simulation = Simulation(ensemble_model; Δt, stop_time)

ensemble_simulation

# ### Free parameters
#
# We construct some prior distributions for our free parameters. We found that it often helps to
# constrain the prior distributions so that neither very high nor very low values for diffusivities
# can be drawn out of the distribution.

priors = (
    κ_skew = ConstrainedNormal(0.0, 1.0, 400.0, 1300.0),
    κ_symmetric = ConstrainedNormal(0.0, 1.0, 700.0, 1700.0)
)

free_parameters = FreeParameters(priors)

# To visualize the prior distributions we randomly sample out values from then and plot the p.d.f.

using CairoMakie
using OceanTurbulenceParameterEstimation.EnsembleKalmanInversions: convert_prior, inverse_parameter_transform

samples(prior) = [inverse_parameter_transform(prior, x) for x in rand(convert_prior(prior), 10000000)]

samples_κ_skew = samples(priors.κ_skew)
samples_κ_symmetric = samples(priors.κ_symmetric)

f = Figure()
axtop = Axis(f[1, 1],
             xlabel = "diffusivities [m² s⁻¹]",
             ylabel = "p.d.f.")
densities = []
push!(densities, density!(axtop, samples_κ_skew))
push!(densities, density!(axtop, samples_κ_symmetric))
Legend(f[1, 2], densities, ["κ_skew", "κ_symmetric"], position = :lb)

save("visualize_prior_diffusivities_baroclinic_adjustment.svg", f); nothing #hide 

# ![](visualize_prior_diffusivities_baroclinic_adjustment.svg)


# ### The inverse problem

# We can construct the inverse problem ``y = G(θ) + η``. Here, ``y`` are the `observations` and ``G`` is the
# `ensemble_model`.
calibration = InverseProblem(observations, ensemble_simulation, free_parameters)

# ### Assert that ``G(θ_*) ≈ y``
#
# As a sanity check we apply the `forward_map` on the calibration after we initialize all ensemble
# members with the true parameter values. We then confirm that the output of the `forward_map` matches
# the observations to machine precision.

G = forward_map(calibration, [θ★])
y = observation_map(calibration)
nothing #hide

# The `forward_map` output `x` is a two-dimensional matrix whose first dimension is the size of the state space
# (here, ``2 N_y N_z``; the 2 comes from the two tracers we used as observations) and whose second dimension is
# the `ensemble_size`. In the case above, all columns of `x` are identical.

mean(G, dims=2) ≈ y

# Next, we construct an `EnsembleKalmanInversion` (EKI) object,

eki = EnsembleKalmanInversion(calibration; noise_covariance = 1e-2)

# and perform few iterations to see if we can converge to the true parameter values.

params = iterate!(eki; iterations = 5)

@show params

# Last, we visualize few metrics regarding how the EKI calibration went about.

θ̅(iteration) = [eki.iteration_summaries[iteration].ensemble_mean...]
varθ(iteration) = eki.iteration_summaries[iteration].ensemble_var

weight_distances = [norm(θ̅(iter) - [θ★[1], θ★[2]]) for iter in 1:eki.iteration]
output_distances = [norm(forward_map(calibration, θ̅(iter))[:, 1] - y) for iter in 1:eki.iteration]
ensemble_variances = [varθ(iter) for iter in 1:eki.iteration]

f = Figure()
lines(f[1, 1], 1:eki.iteration, weight_distances, color = :red, linewidth = 2,
      axis = (title = "Parameter distance",
              xlabel = "Iteration",
              ylabel="|θ̅ₙ - θ⋆|",
              yscale = log10))
lines(f[1, 2], 1:eki.iteration, output_distances, color = :blue, linewidth = 2,
      axis = (title = "Output distance",
              xlabel = "Iteration",
              ylabel="|G(θ̅ₙ) - y|",
              yscale = log10))
ax3 = Axis(f[2, 1:2], title = "Parameter convergence",
           xlabel = "Iteration",
           ylabel = "Ensemble variance",
           yscale = log10)

for (i, pname) in enumerate(free_parameters.names)
    ev = getindex.(ensemble_variances, i)
    lines!(ax3, 1:eki.iteration, ev / ev[1], label = String(pname), linewidth = 2)
end

axislegend(ax3, position = :rt)
save("summary_baroclinic_adjustment.svg", f); nothing #hide 

# ![](summary_baroclinic_adjustment.svg)

# And also we plot the the distributions of the various model ensembles for few EKI iterations to see
# if and how well they converge to the true diffusivity values.

f = Figure()

axtop = Axis(f[1, 1])

axmain = Axis(f[2, 1],
              xlabel = "κ_skew [m² s⁻¹]",
              ylabel = "κ_symmetric [m² s⁻¹]")

axright = Axis(f[2, 2])
scatters = []

for iteration in [1, 2, 3, 6]
    ## Make parameter matrix
    parameters = eki.iteration_summaries[iteration].parameters
    Nensemble = length(parameters)
    Nparameters = length(first(parameters))
    parameter_ensemble_matrix = [parameters[i][j] for i=1:Nensemble, j=1:Nparameters]

    push!(scatters, scatter!(axmain, parameter_ensemble_matrix))
    density!(axtop, parameter_ensemble_matrix[:, 1])
    density!(axright, parameter_ensemble_matrix[:, 2], direction = :y)
end

vlines!(axmain, [κ_skew], color = :red)
vlines!(axtop, [κ_skew], color = :red)

hlines!(axmain, [κ_symmetric], color = :red)
hlines!(axright, [κ_symmetric], color = :red)

colsize!(f.layout, 1, Fixed(300))
colsize!(f.layout, 2, Fixed(200))

rowsize!(f.layout, 1, Fixed(200))
rowsize!(f.layout, 2, Fixed(300))

Legend(f[1, 2], scatters,
       ["Initial ensemble", "Iteration 1", "Iteration 2", "Iteration 5"],
       position = :lb)

hidedecorations!(axtop, grid = false)
hidedecorations!(axright, grid = false)

xlims!(axmain, 350, 1350)
xlims!(axtop, 350, 1350)
ylims!(axmain, 650, 1750)
ylims!(axright, 650, 1750)
xlims!(axright, 0, 0.06)
ylims!(axtop, 0, 0.06)

save("distributions_baroclinic_adjustment.svg", f); nothing #hide 

# ![](distributions_baroclinic_adjustment.svg)