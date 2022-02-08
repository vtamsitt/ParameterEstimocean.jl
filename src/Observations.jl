module Observations

using Oceananigans
using Oceananigans: fields
using Oceananigans.Grids: AbstractGrid
using Oceananigans.Grids: cpu_face_constructor_x, cpu_face_constructor_y, cpu_face_constructor_z
using Oceananigans.Grids: pop_flat_elements, topology, halo_size, on_architecture
using Oceananigans.TimeSteppers: update_state!
using Oceananigans.Fields
using Oceananigans.Utils: SpecifiedTimes
using Oceananigans.Architectures
using Oceananigans.Architectures: arch_array, architecture
using JLD2

import Oceananigans.Fields: set!

using OceanTurbulenceParameterEstimation.Utils: field_name_pairs
using OceanTurbulenceParameterEstimation.Transformations: Transformation, compute_transformation

abstract type AbstractObservation end

struct SyntheticObservations{F, G, T, P, M, Þ} <: AbstractObservation
    field_time_serieses :: F
                   grid :: G
                  times :: T
                   path :: P
               metadata :: M
         transformation :: Þ
end

"""
    SyntheticObservations(path; field_names,
                          transformation = Transformation()),
                          times = nothing,
                          field_time_serieses = nothing,
                          regrid_size = nothing)

Return a time series of synthetic observations generated by Oceananigans.jl's simulations
gridded as Oceananigans.jl fields.
"""
function SyntheticObservations(path=nothing; field_names,
                               transformation = Transformation(),
                               times = nothing,
                               field_time_serieses = nothing,
                               regrid_size = nothing)

    field_names = tupleit(field_names)

    if isnothing(field_time_serieses)
        raw_time_serieses = NamedTuple(name => FieldTimeSeries(path, string(name); times)
                                       for name in field_names)
    else
        raw_time_serieses = field_time_serieses
    end

    raw_grid = first(raw_time_serieses).grid
    times = first(raw_time_serieses).times
    boundary_conditions = first(raw_time_serieses).boundary_conditions

    if isnothing(regrid_size)
        field_time_serieses = raw_time_serieses
        grid = raw_grid

    else # Well, we're gonna regrid stuff
        grid = with_size(regrid_size, raw_grid)

        @info string("Regridding synthetic observations...", '\n',
                     "    original grid: ", summary(raw_grid), '\n',
                     "         new grid: ", summary(grid))

        field_time_serieses = Dict()

        # Re-grid the data in `field_time_serieses`
        for (field_name, ts) in zip(keys(raw_time_serieses), raw_time_serieses)

            #LX, LY, LZ = location(ts[1])
            LX, LY, LZ = infer_location(field_name)

            new_ts = FieldTimeSeries{LX, LY, LZ}(grid, times; boundary_conditions)
        
            # Loop over time steps to re-grid each constituent field in `field_time_series`
            for n = 1:length(times)
                regrid!(new_ts[n], ts[n])
            end
        
            field_time_serieses[field_name] = new_ts
        end

        field_time_serieses = NamedTuple(field_time_serieses)
    end

    # validate_data(fields, grid, times) # might be a good idea to validate the data...
    if !isnothing(path)
        file = jldopen(path)
        metadata = NamedTuple(Symbol(group) => read_group(file[group]) for group in filter(n -> n ∉ not_metadata_names, keys(file)))
        close(file)
    else
        metadata = nothing
    end

    transformation = field_name_pairs(transformation, field_names, "transformation")
    transformation = Dict(name => compute_transformation(transformation[name], field_time_serieses[name])
                         for name in keys(field_time_serieses))

    return SyntheticObservations(field_time_serieses, grid, times, path, metadata, transformation)
end

observation_names(ts::SyntheticObservations) = keys(ts.field_time_serieses)

"""
    observation_names(obs::Vector{<:SyntheticObservations})

Return a Set representing the union of all names in `obs`.
"""
function observation_names(obs_vector::Vector{<:SyntheticObservations})
    names = Set()
    for obs in obs_vector
        push!(names, observation_names(obs)...)
    end

    return names
end

Base.summary(obs::SyntheticObservations) =
    "SyntheticObservations of $(keys(obs.field_time_serieses)) on $(summary(obs.grid))"

Base.summary(obs::Vector{<:SyntheticObservations}) =
    "Vector{<:SyntheticObservations} of $(keys(first(obs).field_time_serieses)) on $(summary(first(obs).grid))"

tupleit(t) = try
    Tuple(t)
catch
    tuple(t)
end

const not_metadata_names = ("serialized", "timeseries")

read_group(group::JLD2.Group) = NamedTuple(Symbol(subgroup) => read_group(group[subgroup]) for subgroup in keys(group))
read_group(group) = group

function with_size(new_size, old_grid)

    topo = topology(old_grid)

    x = cpu_face_constructor_x(old_grid)
    y = cpu_face_constructor_y(old_grid)
    z = cpu_face_constructor_z(old_grid)

    # Remove elements of size and new_halo in Flat directions as expected by grid
    # constructor
    new_size = pop_flat_elements(new_size, topo)
    halo = pop_flat_elements(halo_size(old_grid), topo)

    new_grid = RectilinearGrid(architecture(old_grid), eltype(old_grid);
        size = new_size,
        x = x, y = y, z = z,
        topology = topo,
        halo = halo)

    return new_grid
end

location_guide = Dict(:u => (Face, Center, Center),
                      :v => (Center, Face, Center),
                      :w => (Center, Center, Face))

function infer_location(field_name)
    if field_name in keys(location_guide)
        return location_guide[field_name]
    else
        return (Center, Center, Center)
    end
end

function observation_times(data_path::String)
    file = jldopen(data_path)
    iterations = parse.(Int, keys(file["timeseries/t"]))
    times = [file["timeseries/t/$i"] for i in iterations]
    close(file)
    return times
end

observation_times(observation::SyntheticObservations) = observation.times

function observation_times(obs::Vector)
    @assert all([o.times ≈ obs[1].times for o in obs]) "Observations must have the same times."
    return observation_times(first(obs))
end

#####
##### set! for simulation models and observations
#####

"""
    column_ensemble_interior(observations::Vector{<:SyntheticObservations}, field_name, time_indices::Vector, N_ens)

Return an `Nensemble × Nbatch × Nz` Array of `(1, 1, Nz)` `field_name` data,
given `Nbatch` `SyntheticObservations` objects.
The `Nbatch × Nz` data for `field_name` is copied `Nensemble` times to form a 3D Array.
"""
function column_ensemble_interior(observations::Vector{<:SyntheticObservations},
                                  field_name, time_index, (Nensemble, Nbatch, Nz))

    zeros_column = zeros(1, 1, Nz)
    Nt = length(first(observations).times)

    batched_data = []
    for observation in observations
        fts = observation.field_time_serieses
        if field_name in keys(fts) && time_index <= Nt
            field_column = interior(fts[field_name][time_index])
            push!(batched_data, interior(fts[field_name][time_index]))
        else
            push!(batched_data, zeros_column)
        end
    end

    # Make a Vector of 1D Array into a 3D Array
    flattened_data = cat(batched_data..., dims = 2) # (Nbatch, Nz)
    ensemble_interior = cat((flattened_data for i = 1:Nensemble)..., dims = 1) # (Nensemble, Nbatch, Nz)

    return ensemble_interior
end

function set!(model, obs::SyntheticObservations, time_index=1)
    for field_name in keys(fields(model))
        model_field = fields(model)[field_name]

        if field_name ∈ keys(obs.field_time_serieses)
            obs_field = obs.field_time_serieses[field_name][time_index]
            set!(model_field, obs_field)
        else
            fill!(parent(model_field), 0)
        end
    end

    update_state!(model)

    return nothing
end

function set!(model, observations::Vector{<:SyntheticObservations}, time_index=1)
    for field_name in keys(fields(model))
        model_field = fields(model)[field_name]
        model_field_size = size(model_field)
        Nensemble = model.grid.Nx

        observations_data = column_ensemble_interior(observations, field_name, time_index, model_field_size)
    
        # Reshape `observations_data` to the size of `model_field`'s interior
        reshaped_data = arch_array(architecture(model_field), reshape(observations_data, size(model_field)))
    
        # Sets the interior of field `model_field` to values of `reshaped_data`
        model_field .= reshaped_data
    end

    update_state!(model)

    return nothing
end

#####
##### FieldTimeSeriesCollector for collecting data while a simulation runs
#####

struct FieldTimeSeriesCollector{G, D, F, T}
    grid :: G
    field_time_serieses :: D
    collected_fields :: F
    times :: T
end

"""
    FieldTimeSeriesCollector(collected_fields, times;
                             architecture = Architectures.architecture(first(collected_fields)))

Return a `FieldTimeSeriesCollector` for `fields` of `simulation`.
`fields` is a `NamedTuple` of `AbstractField`s that are to be collected.
"""
function FieldTimeSeriesCollector(collected_fields, times;
                                  architecture = Architectures.architecture(first(collected_fields)))

    grid = on_architecture(architecture, first(collected_fields).grid)
    field_time_serieses = Dict{Symbol, Any}()

    for field_name in keys(collected_fields)
        field = collected_fields[field_name]
        LX, LY, LZ = location(field)
        field_time_series = FieldTimeSeries{LX, LY, LZ}(grid, times)
        field_time_serieses[field_name] = field_time_series
    end

    # Convert to NamedTuple
    field_time_serieses = NamedTuple(name => field_time_serieses[name] for name in keys(collected_fields))

    return FieldTimeSeriesCollector(grid, field_time_serieses, collected_fields, times)
end

function (collector::FieldTimeSeriesCollector)(simulation)
    for field in collector.collected_fields
        compute!(field)
    end

    current_time = simulation.model.clock.time
    time_index = findfirst(t -> t >= current_time, collector.times)

    for field_name in keys(collector.collected_fields)
        field_time_series = collector.field_time_serieses[field_name]
        if architecture(collector.grid) != architecture(simulation.model.grid)
            arch = architecture(collector.grid)
            device_collected_field_data = arch_array(arch, parent(collector.collected_fields[field_name]))
            parent(field_time_series[time_index]) .= device_collected_field_data
        else
            set!(field_time_series[time_index], collector.collected_fields[field_name])
        end
    end

    return nothing
end

#####
##### Initializing simulations
#####

function initialize_simulation!(simulation, observations, time_series_collector, time_index=1)
    set!(simulation.model, observations, time_index)

    times = observation_times(observations)
    initial_time = times[time_index]
    simulation.model.clock.time = initial_time
    simulation.model.clock.iteration = 0
    simulation.model.timestepper.previous_Δt = Inf
    simulation.initialized = false

    # Zero out time series data
    for time_series in time_series_collector.field_time_serieses
        parent(time_series.data) .= 0
    end

    simulation.callbacks[:data_collector] = Callback(time_series_collector, SpecifiedTimes(times...))
    :nan_checker ∈ keys(simulation.callbacks) && pop!(simulation.callbacks, :nan_checker)

    simulation.stop_time = times[end]

    return nothing
end

summarize_metadata(::Nothing) = ""
summarize_metadata(metadata) = keys(metadata)

Base.show(io::IO, obs::SyntheticObservations) =
    print(io, "SyntheticObservations with fields $(propertynames(obs.field_time_serieses))", '\n',
              "├── times: $(obs.times)", '\n',
              "├── grid: $(summary(obs.grid))", '\n',
              "├── path: \"$(obs.path)\"", '\n',
              "├── metadata: ", summarize_metadata(obs.metadata), '\n',
              "└── transformation: $(summary(obs.transformation))")

end # module
