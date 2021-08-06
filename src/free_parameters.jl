# pm.model.closure

function get_free_parameters(closure::AbstractTurbulenceClosure)
    paramnames = Dict()
    paramtypes = Dict()
    kw_params = Dict() # for parameters that are not contained in structs but rather as explicit keyword arguments in `pm.model.closure`
    for pname in propertynames(closure) # e.g. :surface_model
        p = getproperty(closure, pname) # e.g. p = TKESurfaceFlux{Float64}(3.62, 1.31)

        if pname ∈ [:surface_model, :diffusivity_scaling]
        # if typeof(p) <: Union{Oceananigans.TurbulenceClosures.RiDependentDiffusivityScaling, Oceananigans.TurbulenceClosures.TKESurfaceFlux}
            paramnames[pname] = propertynames(p) #e.g. paramnames[:surface_model] = (:Cᵂu★, :CᵂwΔ)
            paramtypes[pname] = typeof(p) #e.g. paramtypes[:surface_model] = TKESurfaceFlux{Float64}

        elseif pname ∈ [:dissipation_parameter, :mixing_length_parameter]
        # elseif typeof(p) <: Number
            kw_params[pname] = p #e.g. kw_params[:dissipation_parameter] = 2.91
        end
    end

    return paramnames, paramtypes, kw_params
end
 
function DefaultFreeParameters(closure::AbstractTurbulenceClosure, freeparamtype)
    paramnames, paramtypes, kw_params = get_free_parameters(closure)
    #e.g. paramnames[:surface_model] = (:Cᵂu★, :CᵂwΔ);
    #     paramtypes[:surface_model] = TKESurfaceFlux{Float64}
    #     kw_params[:dissipation_parameter] = 2.91

    alldefaults = (ptype() for ptype in values(paramtypes))

    freeparams = [] # list of parameter values in the order specified by fieldnames(freeparamtype)
    for pname in fieldnames(freeparamtype) # e.g. :Cᵂu★
        for ptype in alldefaults # e.g. TKESurfaceFlux{Float64}(3.62, 1.31)
            pname ∈ propertynames(ptype) && (push!(freeparams, getproperty(ptype, pname)); break)
            pname == :Cᴰ && (push!(freeparams, kw_params[:dissipation_parameter]); break)
            pname == :Cᴸᵇ && (push!(freeparams, kw_params[:mixing_length_parameter]); break)
        end
    end

    return eval(Expr(:call, freeparamtype, freeparams...)) # e.g. ParametersToOptimize([1.0,2.0,3.0])
end

macro free_parameters(GroupName, parameter_names...)
    N = length(parameter_names)
    parameter_exprs = [:($name :: T; ) for name in parameter_names]
    return esc(quote
        Base.@kwdef mutable struct $GroupName{T} <: FreeParameters{$N, T}
            $(parameter_exprs...)
        end
    end)
end

function new_closure(closure::AbstractTurbulenceClosure, free_parameters)

    paramnames, paramtypes, kw_params = get_free_parameters(closure)
    #e.g. paramnames[:surface_model] = (:Cᵂu★, :CᵂwΔ)
    #e.g. paramtypes[:surface_model] = TKESurfaceFlux{Float64}
    #e.g. kw_params[:dissipation_parameter] = 2.91

    # All keyword arguments to be passed in when defining the new closure
    new_closure_kwargs = kw_params

    # Populate paramdicts with the new values for each parameter name `pname` under `ptypename`
    for ptypename in keys(paramtypes) # e.g. :diffusivity_scaling, :surface_model

        existing_parameters = getproperty(closure, ptypename)

        new_ptype_kwargs = Dict()

        for pname in propertynames(existing_parameters)

            p = pname ∈ propertynames(free_parameters) ?
                    getproperty(free_parameters, pname) :
                    getproperty(existing_parameters, pname)

            new_ptype_kwargs[pname] = p
        end

        # Create new parameter struct for `ptypename` with parameter values given by `new_ptype_kwargs`
        new_closure_kwargs[ptypename] = paramtypes[ptypename](; new_ptype_kwargs...)
    end

    # Include closure properties that do not correspond to model parameters, if any
    for ptypename in propertynames(closure)

        if ptypename ∉ keys(new_closure_kwargs)
            new_closure_kwargs[ptypename] = getproperty(closure, ptypename)
        end

    end

    ClosureType = typeof(closure)
    args = [new_closure_kwargs[x] for x in fieldnames(ClosureType)]
    new_closure = ClosureType(args...)

    # for (ptypename, new_value) in new_closure_kwargs
    #     setproperty!(closure, ptypename, new_value)
    # end

    return new_closure
end

function set!(pm::ParameterizedModel, free_parameters)
    closure = getproperty(pm.model, :closure)
    new_ = new_closure(closure, free_parameters)
    setproperty!(pm.model, :closure, new_)
end