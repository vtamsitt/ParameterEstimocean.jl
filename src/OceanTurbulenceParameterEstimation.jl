module OceanTurbulenceParameterEstimation

export
    SyntheticObservations,
    InverseProblem,
    FreeParameters,
    IdentityNormalization,
    ZScore,
    forward_map,
    forward_run!,
    observation_map,
    observation_map_variance_across_time,
    ConcatenatedOutputMap,
    eki,
    lognormal_with_mean_std,
    iterate!,
    EnsembleKalmanInversion,
    UnscentedKalmanInversion,
    UnscentedKalmanInversionPostprocess,
    ConstrainedNormal

include("Observations.jl")
include("TurbulenceClosureParameters.jl")
include("InverseProblems.jl")
include("EnsembleKalmanInversions.jl")

using .Observations:
    SyntheticObservations,
    ZScore

using .TurbulenceClosureParameters: FreeParameters

using .InverseProblems:
    InverseProblem,
    forward_map,
    forward_run!,
    observation_map,
    observation_map_variance_across_time,
    ConcatenatedOutputMap

using .EnsembleKalmanInversions:
    iterate!,
    EnsembleKalmanInversion,
    UnscentedKalmanInversion,
    UnscentedKalmanInversionPostprocess,
    ConstrainedNormal,
    lognormal_with_mean_std

end # module
