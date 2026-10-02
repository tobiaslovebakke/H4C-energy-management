# =============================================================================
# EM_in_H4C_model_stochastic.jl
#
# Two-stage stochastic mixed-integer linear program (MILP) for the centralised
# operation of a multi-carrier Hub for Circularity (H4C.
#
# The network is a directed graph: nodes are sources, conversion units, storages
# and demands; arcs ("lines") carry exactly one carrier each. The model decides
# the flows on all arcs, the storage levels and the on/off status of all units
# such that the expected operating cost minus the expected revenue is minimised.
#
# Requires JuMP and a MILP solver package (any solver supported by JuMP, chosen
# in the main script) to be loaded by the calling script, together with the
# type definitions (Line, Source, Unit, CG_Unit, Transport_Unit, Multi_Unit,
# Segment_Unit, Storage, Demand).
#
# NOTE: besides its arguments, `h4c_stochastic` reads the following global
# variables, which must be defined before the function is called:
#   carriers         Vector with the names of all carriers (length F)
#   W                Number of scenarios
#   lags             Vector with all distinct line lags (time delays) in the network
#   L                Number of lags minus one (length(lags) == L+1)
#   M_demand         Big-M constant used to relax the upper bound on demand
#   extreme_cgs      Extreme-point matrices of the CG units (used to size G)
#   v_up_ini         Upward demand shifts of the previous horizon   [d, t]
#   v_down_ini       Downward demand shifts of the previous horizon [d, t]
#   simulation_name  Name of the run; used for the Gurobi node-file directory
# =============================================================================

"""
    create_model(optimizer, threads, nodes, nodefile_name)

Create a JuMP model for the solver `optimizer` (any MILP solver supported by JuMP,
e.g. `Gurobi.Optimizer`, `HiGHS.Optimizer` or `CPLEX.Optimizer`) and apply the
solver settings.

`threads` is the number of threads (0 = let the solver decide); it is ignored, with
a warning, by solvers that do not support it. `nodes` and `nodefile_name` are only
used by Gurobi: branch-and-bound nodes are written to the directory
`Nodefiles/<nodefile_name>` once they take up more than `nodes` GB of memory, to
avoid running out of memory on large instances.
"""
function create_model(optimizer, threads, nodes, nodefile_name)
    model = Model(optimizer)
    if solver_name(model) == "Gurobi"
        set_optimizer_attribute(model, "Threads", threads)
        set_optimizer_attribute(model, "NodefileStart", nodes)
        nodefile_dir = joinpath(@__DIR__, "Nodefiles", nodefile_name)
        mkpath(nodefile_dir)
        set_optimizer_attribute(model, "NodefileDir", nodefile_dir)
    elseif threads > 0
        # Solver-independent way of setting the number of threads
        try
            MOI.set(model, MOI.NumberOfThreads(), threads)
        catch e
            e isa MOI.UnsupportedAttribute || rethrow()
            @warn "$(solver_name(model)) does not support setting the number of threads; the solver default is used."
        end
    end
    return model
end

"""
    get_mip_gap(model)

Return the relative MIP gap of the solved `model`, or `NaN` if there is no solution
or the solver does not report a gap.
"""
function get_mip_gap(model)
    has_values(model) || return NaN
    try
        return relative_gap(model)
    catch
        return NaN
    end
end

"""
    apply_time_limit!(model, time_limit)

Limit the solve time of `model` to `time_limit` seconds (`nothing` = no limit).

With Gurobi a *soft* limit is used, see [`make_callback`](@ref). Other solvers
get a regular (hard) time limit, which means that they can stop without having
found a feasible solution.
"""
function apply_time_limit!(model, time_limit)
    if time_limit !== nothing && time_limit > 0
        if solver_name(model) == "Gurobi"
            MOI.set(model, Gurobi.CallbackFunction(), make_callback(model, time_limit))
        else
            try
                set_time_limit_sec(model, time_limit)
            catch e
                e isa MOI.UnsupportedAttribute || rethrow()
                @warn "$(solver_name(model)) does not support a time limit; the solve is not limited in time."
            end
        end
    end
    return nothing
end

"""
    make_callback(model, time_limit)

Create a Gurobi callback implementing a *soft* time limit: the optimisation is
terminated once `time_limit` seconds have passed **and** a feasible solution
(incumbent) has been found. In contrast to Gurobi's `TimeLimit` parameter, the
solver therefore never stops without a solution, but keeps searching until the
first incumbent is available.
"""
function make_callback(model, time_limit)
    function my_callback(cb_data, cb_where::Cint)
        # Only act in the MIP callback, where runtime and incumbent objective are available
        if cb_where == GRB_CB_MIP
            runtime_p = Ref{Cdouble}()
            objbst_p  = Ref{Cdouble}()
            GRBcbget(cb_data, cb_where, GRB_CB_RUNTIME,    runtime_p)
            GRBcbget(cb_data, cb_where, GRB_CB_MIP_OBJBST, objbst_p)

            # objbst < GRB_INFINITY means that an incumbent solution exists
            if runtime_p[] > time_limit && objbst_p[] < GRB_INFINITY
                GRBterminate(unsafe_backend(model))
            end
        end
    end
    return my_callback
end

"""
    h4c_stochastic(lines, sources, units, cg_units, transport_units, multi_units,
                   segment_units, storages, demands, demands_nf, demands_transferable,
                   ini_vec, probs, T, T_hn; optimizer=Gurobi.Optimizer, threads=0,
                   nodes=8, time_limit=nothing)

Build and solve the two-stage stochastic H4C scheduling model.

The first `T_hn` time steps are "here-and-now": the commitment decisions (and the
flows from sources flagged as `here_and_now`) must be identical in all scenarios
(non-anticipativity). The remaining time steps are scenario-dependent recourse.

# Arguments
- `lines`: arcs of the network. Each line has a `from` and `to` node, a `carrier`,
  a `lag` (delay in time steps between sending and arrival), flow bounds
  `min_cap`/`max_cap` and, for transport routes, `distance` and `tau_transport`.
- `sources`: supply nodes with scenario-dependent `price[t,w]` and availability `output[t,w]`.
- `units`: standard conversion units (fixed conversion matrix, on/off status).
- `cg_units`: units whose operating region is the convex hull of a set of extreme points.
- `transport_units`: transport fleets that ship a carrier over routes (lines) in discrete trips.
- `multi_units`: multi-state units with the states "on", "standby" and "off".
- `segment_units`: units with a piecewise (segment-wise) conversion, where the active
  segment is determined by the level of a storage.
- `storages`: storages with capacities, efficiencies and losses.
- `demands`: all demand nodes (used for the revenue term in the objective).
- `demands_nf`: the non-flexible demands.
- `demands_transferable`: the demands that can be shifted in time.
- `ini_vec`: `Dict` with the solution of the previous horizon (rolling horizon). The last
  column (`end`) of each entry is the time step directly before `t = 1`.
- `probs`: scenario probabilities (length `W`).
- `T`: number of time steps in the horizon.
- `T_hn`: number of here-and-now time steps (`T_hn <= T`).

# Keyword arguments
- `optimizer`: the solver, e.g. `Gurobi.Optimizer` (default) or `HiGHS.Optimizer`.
- `threads`: number of threads for the solver (0 = automatic).
- `nodes`: memory threshold (in GB) after which Gurobi writes branch-and-bound nodes to disk
  (ignored by other solvers).
- `time_limit`: time limit in seconds, see [`apply_time_limit!`](@ref). `nothing` = no limit.

# Returns
A `Dict` with the values of all decision variables (indexed as in the model, last index
is the scenario) and the entries `:status`, `:objective` (expected objective over the full
horizon), `:objective_hn` (expected objective over the here-and-now time steps only),
`:solve_time` (s) and `:mip_gap`. If no feasible solution was found, all variable entries
are zero arrays and the objective entries are `NaN`.
"""
function h4c_stochastic(
    lines::Vector{<:Line},
    sources::Vector{<:Source},
    units::Vector{<:Unit},
    cg_units::Vector{<:CG_Unit},
    transport_units::Vector{<:Transport_Unit},
    multi_units::Vector{<:Multi_Unit},
    segment_units::Vector{<:Segment_Unit},
    storages::Vector{<:Storage},
    demands::Vector{<:Demand},
    demands_nf::Vector{<:Demand},
    demands_transferable::Vector{<:Demand},
    ini_vec::Dict,
    probs::Vector{<:Any},
    T, T_hn;
    optimizer=Gurobi.Optimizer,
    threads=0,
    nodes=8,
    time_limit::Union{Nothing, Real} = nothing)



    # -------------------------------------------------------------------------
    # Set sizes
    # -------------------------------------------------------------------------
    U          = size(units,1)
    U_CG       = length(cg_units)
    U_trans    = length(transport_units)
    U_multi    = length(multi_units)
    U_segment = length(segment_units)
    A          = size(lines,1)
    E          = size(sources,1)
    S          = size(storages,1)
    D          = size(demands,1)
    D_nf       = length(demands_nf)
    D_transfer = length(demands_transferable)
    
    # Scenario probabilities (note: shadows Julia's constant `pi` inside this function)
    pi = probs
    F          = size(carriers,1)   # Number of carriers (`carriers` is a global)

    # G: maximum number of extreme points over all CG units
    if !isempty(cg_units)
        G    = maximum(size.(extreme_cgs, 2))
    else
        G = 0
    end

    # Q: maximum number of states over all multi-state units
    if !isempty(multi_units)
        state_vec = getfield.(multi_units, :states)
        Q    = maximum(length.(state_vec))
    else
        Q = 0
    end

    # I: maximum number of segments over all segment units
    if !isempty(segment_units)
        I =maximum(getfield.(segment_units, :num_segments))
    else
        I = 0
    end

    # Transport routes: every line leaving the node of a transport unit is a route of that unit.
    #   num_routes[u]     number of routes of transport unit u
    #   R                 maximum number of routes over all transport units
    #   route_lines[u,r]  index of the line belonging to route r of unit u
    #   tau_routes[u,r]   number of time steps a vehicle is occupied by a trip on route r
    #   tau_max           longest trip duration in the network
    if !isempty(transport_units)
        num_routes = []
        tau_routes = []
        for u in transport_units
            sum_routes = sum(1 for a in 1:A if lines[a].from == u.node)
            push!(num_routes,sum_routes)
        end
        R = maximum(num_routes)
        route_lines = zeros(Int, U_trans,R)
        tau_routes = zeros(Int, U_trans,R)
        for u in 1:U_trans
            r = 1
            for a in 1:A
                if lines[a].from == transport_units[u].node
                    tau_routes[u,r] = lines[a].tau_transport
                    route_lines[u,r] = a
                    r = r + 1
                end
            end
        end
        tau_transports = []
        for a in 1:A
            push!(tau_transports,lines[a].tau_transport)
        end
        tau_max = maximum(tau_transports)
    else    
        R = 0
        tau_max = 0
        tau_routes = zeros(Int,0,0)
        route_lines = zeros(Int,0,0)
    end

    tau_routes = [Int(x) for x in tau_routes]

    
    print(pi)

    # -------------------------------------------------------------------------
    # Model and solver settings
    # -------------------------------------------------------------------------
    H4C = create_model(optimizer, threads, nodes, "stochastic_$(simulation_name)")

    # -------------------------------------------------------------------------
    # Decision variables
    # Index convention: a = line, s = storage, u = unit, f = carrier, t = time step,
    # w = scenario. All variables are scenario-dependent.
    # -------------------------------------------------------------------------
    @variable(H4C, x[1:A, 1:T, 1:W] >= 0)          # Flow on each arc


    @variable(H4C, y[1:S, 1:T, 1:W] >= 0)           # Storage energy content


    @variable(H4C, z[1:U, 1:T, 1:W], Bin)           # On variable of each production unit
    @variable(H4C, z_start[1:U, 1:T, 1:W], Bin)     # Start variable of each production unit
    @variable(H4C, z_stop[1:U, 1:T, 1:W], Bin)      # Stop variable of each production unit

    # Units without start/stop cost, start-up time and minimum load never benefit from being
    # switched off, so their binaries are fixed to reduce the size of the MILP.
    for u in 1:U
        if units[u].start_stop_cost == 0 && units[u].start_up_time==0 && all(units[u].min_input .== 0) && all(units[u].min_output .== 0)
            fix.(z[u,:,:], 1; force=true)
            # t=1 is left free: its z_start/z_stop value depends on ini_vec[:z][u,end] via
            # unit_start_stop_ini and can be 1 if the unit was off at the end of the prior horizon.
            fix.(z_start[u,2:T,:], 0; force=true)
            fix.(z_stop[u,2:T,:], 0; force=true)
        end
    end

    # CG units: alpha are the convex-combination weights of the extreme points g
    @variable(H4C, 0 <= alpha[1:U_CG, 1:G, 1:T, 1:W] <= 1)
    @variable(H4C,      z_cg[1:U_CG, 1:T, 1:W],       Bin)
    @variable(H4C,      z_cg_start[1:U_CG, 1:T, 1:W], Bin)
    @variable(H4C,      z_cg_stop[1:U_CG, 1:T, 1:W],  Bin)


    # Multi-state units: x_multi_main is the level of the main output while in state q
    @variable(H4C, x_multi_main[1:U_multi, 1:Q, 1:T, 1:W] >= 0)
    @variable(H4C, z_multi_on[1:U_multi, 1:T, 1:W], Bin)
    @variable(H4C, z_multi_h_start[1:U_multi, 1:T, 1:W], Bin)    #Hot start (from standby to on)
    @variable(H4C, z_multi_c_start[1:U_multi, 1:T, 1:W], Bin)    #Cold start (from off to on)
    @variable(H4C, z_multi_h_stop[1:U_multi, 1:T, 1:W], Bin)     #Hot stop (from on to standby)
    @variable(H4C, z_multi_c_stop[1:U_multi, 1:T, 1:W], Bin)     #Cold stop (from on to off)
    @variable(H4C, z_multi_state[1:U_multi, 1:Q, 1:T, 1:W], Bin) #Binary variable keeping track which state is activated


    # Segment units: x_segment_in is the input of carrier f that is processed in segment i
    @variable(H4C, x_segment_in[1:U_segment, 1:I, 1:F, 1:T, 1:W] >= 0)
    @variable(H4C, z_segment_state[1:U_segment, 1:I, 1:T, 1:W], Bin) #Binary variable keeping track which state is activated
    @variable(H4C, z_segment_on[1:U_segment, 1:T, 1:W], Bin)
    @variable(H4C, z_segment_start[1:U_segment, 1:T, 1:W], Bin)     # Start variable of each production unit
    @variable(H4C, z_segment_stop[1:U_segment, 1:T, 1:W], Bin)      # Stop variable of each production unit


    # Transport units: 1 if a trip of unit u departs on route r at time t
    @variable(H4C, z_transport[1:U_trans, 1:R, 1:T, 1:W], Bin)

    # Transferable demands: amount by which the demand is shifted up / down at time t
    @variable(H4C, v_up[1:D_transfer, 1:T, 1:W]   >= 0)
    @variable(H4C, v_down[1:D_transfer, 1:T, 1:W] >= 0)



    # -------------------------------------------------------------------------
    # Objective: minimise the expected net cost over all scenarios, consisting of
    #   + flow cost on the lines (cost per unit of flow)
    #   + purchase cost at the sources
    #   + start/stop and operating cost of the standard units
    #   + start/stop and operating cost of the CG units
    #   + trip cost of the transport units (fixed + distance-based + time-based)
    #   - revenue from the delivery to the demands
    #   + operating cost and cold/hot stop cost of the multi-state units
    #   + start/stop and operating cost of the segment units
    # Operating costs are charged per unit of output flow of each carrier.
    # -------------------------------------------------------------------------
    @objective(H4C, Min, sum(pi[w]*(sum(lines[a].cost*x[a,t,w] for a in 1:A, t in 1:T) +
                        sum(sources[e].price[t,w]*x[a,t,w] for e in 1:E, t in 1:T, a in 1:A if lines[a].from == sources[e].node) +
                        sum(units[u].start_stop_cost*z_stop[u,t,w] for u in 1:U, t in 1:T)+
                        sum(units[u].cost_operating[f]*x[a,t,w] for u in 1:U, f in 1:F, t in 1:T, a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) +
                        sum(cg_units[u].start_stop_cost*z_cg_stop[u,t,w] for u in 1:U_CG, t in 1:T) +
                        sum(cg_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_CG, f in 1:F, t in 1:T, a in 1:A if lines[a].from == cg_units[u].node && lines[a].carrier == carriers[f]) +
                        sum(z_transport[u,r,t,w]*(transport_units[u].cost_fixed + transport_units[u].cost_distance*lines[route_lines[u,r]].distance + transport_units[u].cost_time*tau_routes[u,r]) for u in 1:U_trans, r in 1:R, t in 1:T if route_lines[u,r] > 0) -
                        sum(demands[d].price[t,w]*x[a,t,w] for d in 1:D, t in 1:T, a in 1:A if lines[a].to == demands[d].node) +
                        sum(multi_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_multi, f in 1:F, t in 1:T, a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f]) +
                        sum(z_multi_c_stop[u,t,w]*multi_units[u].start_stop_cost[2] for u in 1:U_multi, t in 1:T) + 
                        sum(z_multi_h_stop[u,t,w]*multi_units[u].start_stop_cost[1] for u in 1:U_multi, t in 1:T) +
                        sum(segment_units[u].start_stop_cost*z_segment_stop[u,t,w] for u in 1:U_segment, t in 1:T) +
                        sum(segment_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_segment, f in 1:F, t in 1:T, a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f])) for w in 1:W)) 

    # -------------------------------------------------------------------------
    # Standard units
    # -------------------------------------------------------------------------
    # Input and output of each carrier lie between the minimum and maximum load
    # when the unit is on, and are zero when it is off. Inputs are counted when they
    # arrive at the unit, i.e. taking the line lags into account.
    @constraint(H4C, x_max_in[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                        sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                        <= z[u,t,w]* units[u].max_input[f])
    @constraint(H4C, x_min_in[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                        sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                        >= z[u,t,w]* units[u].min_input[f])

    @constraint(H4C, x_max_out[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) 
                                                            <= z[u,t,w]* units[u].max_output[f])
    @constraint(H4C, x_min_out[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) 
                                                            >= z[u,t,w]* units[u].min_output[f])


    # Start/stop logic: a change of the on-status triggers a start or a stop.
    # For t = 1 the status at the end of the previous horizon (ini_vec) is used.
    @constraint(H4C, unit_start_stop[u=1:U, t=2:T, w=1:W], z_start[u,t,w] - z_stop[u,t,w] == z[u,t,w]- z[u,t-1,w])
    @constraint(H4C, unit_start_stop_ini[u=1:U, w=1:W],    z_start[u,1,w] - z_stop[u,1,w] == z[u,1,w]- ini_vec[:z][u,end])

    # A unit cannot start and stop in the same time step
    @constraint(H4C, unit_ss_sum[u=1:U, t=1:T, w=1:W],     z_start[u,t,w] + z_stop[u,t,w] <= 1)

    # Ramping limits on the output of each carrier. In a start (stop) time step the
    # limit is widened by the minimum output, so that the unit can reach (leave) its minimum load.
    @constraint(H4C, unit_ramp_up[u=1:U, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_up[f] + z_start[u,t,w]*units[u].min_output[f])
    @constraint(H4C, unit_ramp_down[u=1:U, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_down[f] + z_stop[u,t,w]*units[u].min_output[f])

    # Ramping limits in time step 1, relative to the last output of the previous horizon (ini_vec)
    @constraint(H4C, unit_ramp_up_ini[u=1:U, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_up[f] + z_start[u,t,w]*units[u].min_output[f])
    @constraint(H4C, unit_ramp_down_ini[u=1:U, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_down[f] + z_stop[u,t,w]*units[u].min_output[f])

    # -------------------------------------------------------------------------
    # Transport units
    # -------------------------------------------------------------------------
    # Fleet capacity: the number of vehicles that are under way at time t (trips that
    # departed within the last tau_routes time steps, including trips that departed in
    # the previous horizon) cannot exceed the fleet size
    @constraint(H4C, fleet_capacity[u=1:U_trans, t=1:T, w=1:W],  sum(z_transport[u,r,t1,w] for r in 1:R, t1 in maximum([1,t-tau_routes[u,r]+1]):t if route_lines[u,r] > 0) + 
                                                                 sum(ini_vec[:z_transport][u,r,end+t1] for r in 1:R, t1 in t-tau_routes[u,r]+1:0 if route_lines[u,r] > 0 && (t1-tau_routes[u,r]+1) <= 0) <= transport_units[u].fleet_cap)


    # The load of a trip lies between the minimum and maximum load; no flow without a trip
    # Only the routes that exist (route_lines[u,r] > 0) are used: units with fewer routes than R
    # have empty route slots, in which no trips can take place.
    @constraint(H4C, min_transport[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] > 0], x[route_lines[u,r],t,w] >= z_transport[u,r,t,w]*transport_units[u].min_output)
    @constraint(H4C, max_transport[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] > 0], x[route_lines[u,r],t,w] <= z_transport[u,r,t,w]*transport_units[u].max_output)
    @constraint(H4C, no_trip_empty_route[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] == 0], z_transport[u,r,t,w] == 0)

    # Everything that enters the transport node is shipped over one of its routes
    # (inflow counted when it arrives at the depot, i.e. taking the line lags into account)
    @constraint(H4C, transport_balance[u=1:U_trans, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == transport_units[u].node && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == transport_units[u].node && lines[a].lag == lags[l] && t-lags[l] <= 0)
                                                                   == sum(x[route_lines[u,r],t,w] for r in 1:R if route_lines[u,r] > 0))

    # -------------------------------------------------------------------------
    # Storage balance
    # -------------------------------------------------------------------------
    # Level at t = level at t-1 minus losses (proportional a_loss and constant b_loss term)
    #              + charged inflow * charge efficiency - discharged outflow / discharge efficiency.
    #
    # Line lags: a flow sent over line a at time t arrives at time t + lines[a].lag. The
    # inflow at time t is therefore x[a, t-lag]. If t-lag falls before the start of the
    # horizon, the flow was sent in the previous horizon and is taken from ini_vec[:x]
    # (a constant). This pair of sums is used for all lagged inflows in this model.
    @constraint(H4C, y_update[s = 1:S, t=2:T, w=1:W], y[s,t,w] == y[s,t-1,w]*(1-storages[s].a_loss[t,w]) + storages[s].b_loss[t,w]  + 
                                                                sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] >= 1)*storages[s].charge_eff     + 
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] <= 0)*storages[s].charge_eff - 
                                                                    sum(x[a,t,w] for a in 1:A if lines[a].from == storages[s].node)/storages[s].discharge_eff)


    

    # Storage balance for t = 1, starting from the final level of the previous horizon
    @constraint(H4C, y_update_ini[s = 1:S, w=1:W],    y[s,1,w] == ini_vec[:y][s,end]*(1-storages[s].a_loss[1,w]) + storages[s].b_loss[1,w] + 
                                                                sum(x[a,1-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && 1-lags[l] >= 1)*storages[s].charge_eff     + 
                                                                sum(ini_vec[:x][a,end+1-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && 1-lags[l] <= 0)*storages[s].charge_eff -  
                                                                sum(x[a,1,w] for a in 1:A if lines[a].from == storages[s].node)/storages[s].discharge_eff)


    # Conversion of the standard units: the output of carrier f1 equals the (lagged) input
    # of carrier f multiplied by the conversion factor conv_matrix[f,f1]
    @constraint(H4C, unit_balance[u=1:U, f=1:F, f1=1:F, t=1:T, w=1:W], sum(units[u].conv_matrix[f,f1]*x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                    sum(units[u].conv_matrix[f,f1]*ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0)  -
                                                                    sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f1] && units[u].conv_matrix[f,f1] != 0)  == 0)



    
                                                            
    # -------------------------------------------------------------------------
    # Sources
    # -------------------------------------------------------------------------
    # The total outflow of a source is limited by its availability in scenario w
    @constraint(H4C, source_balance[e=1:E, t=1:T, w=1:W],         sum(x[a,t,w] for a in 1:A if lines[a].from    == sources[e].node) <= sources[e].output[t,w])
    # Non-anticipativity for sources flagged as here_and_now (e.g. day-ahead purchases):
    # their outflow in the first T_hn time steps must be equal in all scenarios
    if W > 1
        @constraint(H4C, source_here_and_now[e=1:E, t=1:T_hn, w=2:W], sum(x[a,t,w-1] for a in 1:A if lines[a].from  == sources[e].node)*sources[e].here_and_now
                                                                   == sum(x[a,t,w] for a in 1:A if lines[a].from    == sources[e].node)*sources[e].here_and_now) #Source non-anticipativity
    end
                                                               
    # -------------------------------------------------------------------------
    # Demands
    # -------------------------------------------------------------------------
    # Non-flexible demands: the (lagged) inflow must at least cover the demand. If
    # fulfill_exactly = 1 the inflow must equal the demand; otherwise the upper bound
    # is relaxed with the big-M constant M_demand (surplus delivery allowed).
    @constraint(H4C, demand_lower[d=1:D_nf, t=1:T, w=1:W],    sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     + 
                                                              sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) >= demands_nf[d].demand[t,w])
    @constraint(H4C, demand_upper[d=1:D_nf, t=1:T, w=1:W],    sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                              sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= demands_nf[d].fulfill_exactly*demands_nf[d].demand[t,w] + 
                                                                                                                                                                                                    (1-demands_nf[d].fulfill_exactly) * M_demand)


    # Transferable demands: as above, but the demand is shifted by v_up - v_down
    @constraint(H4C, demand_transfer_lower[d=1:D_transfer, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     + 
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) >= demands_transferable[d].demand[t,w] + v_up[d,t,w] - v_down[d,t,w])
    @constraint(H4C, demand_transfer_upper[d=1:D_transfer, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= demands_transferable[d].fulfill_exactly*demands_transferable[d].demand[t,w] + v_up[d,t,w] - v_down[d,t,w] + 
                                                                                                                                                                                                                (1-demands_transferable[d].fulfill_exactly) * M_demand)

    # The shift in each time step is limited to a fraction (flex_factor) of the demand
    @constraint(H4C, demand_transfer_up[d=1:D_transfer, t=1:T, w=1:W],   v_up[d,t,w]   <= demands_transferable[d].flexibility["flex_factor"][t,w] * demands_transferable[d].demand[t,w])
    @constraint(H4C, demand_transfer_down[d=1:D_transfer, t=1:T, w=1:W], v_down[d,t,w] <= demands_transferable[d].flexibility["flex_factor"][t,w] * demands_transferable[d].demand[t,w])

    # Shifted demand is only moved in time, not curtailed: within every window of
    # flex_interval time steps the upward and downward shifts must cancel out. Windows
    # that start before t = 1 use the shifts of the previous horizon (v_up_ini, v_down_ini).
    @constraint(H4C, demand_transfer_sum[d=1:D_transfer, t=1:T, w=1:W],  sum(v_up[d,t1,w]   for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1>=1) + sum(v_up_ini[d,end+t1]   for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1<=0) 
                                                                    == sum(v_down[d,t1,w] for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1>=1) + sum(v_down_ini[d,end+t1] for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1<=0))


                                                                                                                                                                        

    # -------------------------------------------------------------------------
    # Storage capacities: energy content, charging power and discharging power
    # -------------------------------------------------------------------------
    @constraint(H4C, y_max[s = 1:S, t=1:T, w=1:W],              y[s,t,w]                                                         <= storages[s].energy_cap)
    @constraint(H4C, y_charge_max[s = 1:S, t=1:T, w=1:W],       sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to   == storages[s].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= storages[s].charge_cap)

    # Discharge: the flow sent out of the storage in time step t (lags only affect arrival)
    @constraint(H4C, y_discharge_max[s = 1:S, t=1:T, w=1:W],    sum(x[a,t,w] for a in 1:A if lines[a].from == storages[s].node) <= storages[s].discharge_cap)

    # -------------------------------------------------------------------------
    # Minimum up and down times of the standard units
    # -------------------------------------------------------------------------
    # After a stop (start) at time t the unit stays off (on) for at least min_down_time
    # (min_up_time) time steps. The window is truncated at the end of the horizon.
    @constraint(H4C, unit_min_down_t[u=1:U, t=1:T, w=1:W], sum(z[u,t1,w] for t1 in t:min(t+units[u].min_down_time-1, T)) <= min(units[u].min_down_time, T-t+1) * (1 - z_stop[u,t,w]))
    @constraint(H4C, unit_min_up_t[u=1:U, t=1:T, w=1:W],   sum(z[u,t1,w] for t1 in t:min(t+units[u].min_up_time-1, T))   >= min(units[u].min_up_time, T-t+1) * z_start[u,t,w])

    # Carry-over from the previous horizon: a stop (start) that happened less than
    # min_down_time (min_up_time) time steps before t = 1 still binds the first time steps
    @constraint(H4C, unit_min_down_t_ini[u=1:U, t=1:T, w=1:W; t <= units[u].min_down_time-1], sum(z[u,t1,w] for t1 in 1:t) <= t * (1 - ini_vec[:z_stop][u, end-units[u].min_down_time+1+t]))
    @constraint(H4C, unit_min_up_t_ini[u=1:U, t=1:T, w=1:W; t <= units[u].min_up_time-1],     sum(z[u,t1,w] for t1 in 1:t)   >= t * ini_vec[:z_start][u, end-units[u].min_up_time+1+t])


    # -------------------------------------------------------------------------
    # CG units
    # The operating point is a convex combination (weights alpha) of the extreme
    # points g. `fuel[f,g]` is the input and `extreme[f,g]` the output of carrier f
    # in extreme point g.
    # -------------------------------------------------------------------------
    # Input of each carrier follows from the convex combination of the extreme points
    @constraint(H4C, cg_inflow[u=1:U_CG, f=1:F, t=1:T, w=1:W],  sum(alpha[u,g,t,w]*cg_units[u].fuel[f,g] for g in 1:G) == 
                                                                sum(x[a,t-lags[l],w] for  a in 1:A, l in 1:L+1 if lines[a].to == cg_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for  a in 1:A, l in 1:L+1 if lines[a].to == cg_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0))

    # Output of each carrier follows from the same convex combination
    @constraint(H4C, alpha_out[u=1:U_CG, f=1:F, t=1:T, w=1:W],  sum(alpha[u,g,t,w]*cg_units[u].extreme[f,g] for g in 1:G)
                                                                ==  sum(x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]))

    # The weights sum to one when the unit is on and are all zero when it is off
    @constraint(H4C, alpha_on[u=1:U_CG, t=1:T, w=1:W],          sum(alpha[u,g,t,w] for g in 1:G) == z_cg[u,t,w])


    # Start/stop logic and ramping limits, analogous to the standard units
    @constraint(H4C, unit_cg_start_stop[u=1:U_CG, t=2:T, w=1:W], z_cg_start[u,t,w] - z_cg_stop[u,t,w] == z_cg[u,t,w]- z_cg[u,t-1,w])
    @constraint(H4C, unit_cg_start_stop_ini[u=1:U_CG, w=1:W],    z_cg_start[u,1,w] - z_cg_stop[u,1,w] == z_cg[u,1,w]- ini_vec[:z_cg][u,end])

    @constraint(H4C, unit_cg_ss_sum[u=1:U_CG, t=1:T, w=1:W],     z_cg_start[u,t,w] + z_cg_stop[u,t,w] <= 1)

    @constraint(H4C, unit_cg_ramp_up[u=1:U_CG, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_up[f]   + z_cg_start[u,t,w]*minimum(cg_units[u].extreme[f,:]))
    @constraint(H4C, unit_cg_ramp_down[u=1:U_CG, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_down[f] + z_cg_stop[u,t,w]*minimum(cg_units[u].extreme[f,:]))

    # Ramping limits in time step 1, relative to the last output of the previous horizon (ini_vec)
    @constraint(H4C, unit_cg_ramp_up_ini[u=1:U_CG, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_up[f]   + z_cg_start[u,t,w]*minimum(cg_units[u].extreme[f,:]))
    @constraint(H4C, unit_cg_ramp_down_ini[u=1:U_CG, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_down[f] + z_cg_stop[u,t,w]*minimum(cg_units[u].extreme[f,:]))

    # CG units: forward-looking, capped at T
    @constraint(H4C, cg_min_down_t[u=1:U_CG, t=1:T, w=1:W], sum(z_cg[u,t1,w] for t1 in t:min(t+cg_units[u].min_down_time-1, T)) <= min(cg_units[u].min_down_time, T-t+1) * (1 - z_cg_stop[u,t,w]))

    @constraint(H4C, cg_min_up_t[u=1:U_CG, t=1:T, w=1:W],   sum(z_cg[u,t1,w] for t1 in t:min(t+cg_units[u].min_up_time-1, T))   >= min(cg_units[u].min_up_time, T-t+1) * z_cg_start[u,t,w])

    # CG carry-over from previous day
    @constraint(H4C, cg_min_down_t_ini[u=1:U_CG, t=1:T, w=1:W; t <= cg_units[u].min_down_time-1], sum(z_cg[u,t1,w] for t1 in 1:t) <= t * (1 - ini_vec[:z_cg_stop][u, end-cg_units[u].min_down_time+1+t]))

    @constraint(H4C, cg_min_up_t_ini[u=1:U_CG, t=1:T, w=1:W; t <= cg_units[u].min_up_time-1],   sum(z_cg[u,t1,w] for t1 in 1:t)   >= t * ini_vec[:z_cg_start][u, end-cg_units[u].min_up_time+1+t])
    



    # -------------------------------------------------------------------------
    # Multi-state units
    # Each unit is in exactly one state q per time step ("on", "standby" or "off";
    # several states of the same type are allowed). All parameters are state-dependent.
    # -------------------------------------------------------------------------
    # Input and output of each carrier lie within the bounds of the active state
    @constraint(H4C, x_multi_low_in_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                                   >= sum(multi_units[u].min_input[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    @constraint(H4C, x_multi_high_in_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                                   <= sum(multi_units[u].max_input[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    @constraint(H4C, x_multi_low_out_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W],  sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f])
                                                                   >= sum(multi_units[u].min_output[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))
    @constraint(H4C, x_multi_high_out_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f])
                                                                   <= sum(multi_units[u].max_output[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    

    
    # Conversion: in state q, the input and output of each carrier are affine functions
    # of the main output: a[q,f] * x_multi_main + b[q,f] (b is a fixed consumption/production
    # that also applies at zero load, e.g. standby consumption)
    @constraint(H4C, multi_unit_balance_in[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) == 
                                                                   sum(x_multi_main[u,q,t,w]*multi_units[u].a_input[q,f] + z_multi_state[u,q,t,w]*multi_units[u].b_input[q,f] for q in 1:Q))

    @constraint(H4C, multi_unit_balance_out[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f]) == 
                                                                   sum(x_multi_main[u,q,t,w]*multi_units[u].a_output[q,f] + z_multi_state[u,q,t,w]*multi_units[u].b_output[q,f] for q in 1:Q))
    
    
    # The main output in state q lies within the bounds of that state and is zero
    # when the state is not active
    @constraint(H4C, multi_unit_main_low[u=1:U_multi, q=1:Q, t=1:T, w=1:W],  x_multi_main[u,q,t,w] >= sum(multi_units[u].min_output[q,f]*z_multi_state[u,q,t,w] for f in 1:F if multi_units[u].main_output[f]==1))
    @constraint(H4C, multi_unit_main_high[u=1:U_multi, q=1:Q, t=1:T, w=1:W], x_multi_main[u,q,t,w] <= sum(multi_units[u].max_output[q,f]*z_multi_state[u,q,t,w] for f in 1:F if multi_units[u].main_output[f]==1))
                                                                           
    # State transitions:
    #   multi_unit_ss              a change of the on-status is a (hot or cold) start or stop
    #   multi_unit_hot_ss          entering/leaving standby is a hot stop/hot start
    #   multi_unit_cold_ss         entering/leaving off is a cold stop/cold start
    #   multi_unit_off_to_standby  a direct transition from off to standby is not allowed
    @constraint(H4C, multi_unit_ss[u=1:U_multi, t=2:T, w=1:W],             z_multi_h_start[u,t,w] + z_multi_c_start[u,t,w] -  z_multi_h_stop[u,t,w] - z_multi_c_stop[u,t,w] == z_multi_on[u,t,w] - z_multi_on[u,t-1,w])
    @constraint(H4C, multi_unit_hot_ss[u=1:U_multi, t=2:T, w=1:W],         z_multi_h_stop[u,t,w]  - z_multi_h_start[u,t,w] == sum(z_multi_state[u,q,t,w] - z_multi_state[u,q,t-1,w] for q in 1:Q if multi_units[u].states[q]=="standby"))
    @constraint(H4C, multi_unit_cold_ss[u=1:U_multi, t=2:T, w=1:W],        z_multi_c_stop[u,t,w]  - z_multi_c_start[u,t,w] == sum(z_multi_state[u,q,t,w] - z_multi_state[u,q,t-1,w]  for q in 1:Q if multi_units[u].states[q]=="off"))
    @constraint(H4C, multi_unit_off_to_standby[u=1:U_multi, t=2:T, w=1:W], sum(z_multi_state[u,q,t-1,w]  for q in 1:Q if multi_units[u].states[q]=="off") + sum(z_multi_state[u,q,t,w]  for q in 1:Q if multi_units[u].states[q]=="standby") <= 1)

    
    
    # The same state transitions for t = 1, relative to the end of the previous horizon
    @constraint(H4C, multi_unit_ss_ini[u=1:U_multi, w=1:W],                z_multi_h_start[u,1,w] + z_multi_c_start[u,1,w] -  z_multi_h_stop[u,1,w] - z_multi_c_stop[u,1,w] == z_multi_on[u,1,w] - ini_vec[:z_multi_on][u,end])
    @constraint(H4C, multi_unit_hot_ss_ini[u=1:U_multi, w=1:W],            z_multi_h_stop[u,1,w]  - z_multi_h_start[u,1,w] == sum(z_multi_state[u,q,1,w] - ini_vec[:z_multi_state][u,q,end] for q in 1:Q if multi_units[u].states[q]=="standby"))
    @constraint(H4C, multi_unit_cold_ss_ini[u=1:U_multi, w=1:W],           z_multi_c_stop[u,1,w]  - z_multi_c_start[u,1,w] == sum(z_multi_state[u,q,1,w] - ini_vec[:z_multi_state][u,q,end]  for q in 1:Q if multi_units[u].states[q]=="off"))
    @constraint(H4C, multi_unit_off_to_standby_ini[u=1:U_multi, w=1:W],    sum(ini_vec[:z_multi_state][u,q,end]  for q in 1:Q if multi_units[u].states[q]=="off") + sum(z_multi_state[u,q,1,w]  for q in 1:Q if multi_units[u].states[q]=="standby") <= 1)
    
    
    # At most one start or stop event per time step
    @constraint(H4C, multi_unit_ss_sum[u=1:U_multi, t=1:T, w=1:W], z_multi_h_start[u,t,w] + z_multi_c_start[u,t,w] + z_multi_h_stop[u,t,w] + z_multi_c_stop[u,t,w] <= 1)
    

    # Exactly one state is active; the unit is "on" if one of its on-states is active
    @constraint(H4C, multi_unit_state[u=1:U_multi, t=1:T, w=1:W], sum(z_multi_state[u,q,t,w] for q in 1:Q) == 1)

    @constraint(H4C, multi_unit_on_state[u=1:U_multi, t=1:T, w=1:W], sum(z_multi_state[u,q,t,w] for q in 1:Q if multi_units[u].states[q]=="on") == z_multi_on[u,t,w])

        
    # Ramping limits on the output, widened in time steps with a start or stop
    @constraint(H4C, multi_unit_ramp_up[u=1:U_multi, f=1:F, t=2:T, w=1:W],    sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_up[f]   + (z_multi_h_start[u,t,w]+z_multi_c_start[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    @constraint(H4C, multi_unit_ramp_down[u=1:U_multi, f=1:F, t=2:T, w=1:W],  sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_down[f] + (z_multi_h_stop[u,t,w]+z_multi_c_stop[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))


    # Ramping limits in time step 1, relative to the last output of the previous horizon (ini_vec)
    @constraint(H4C, multi_unit_ramp_up_ini[u=1:U_multi, f=1:F, t=1:1, w=1:W],    sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_up[f]   + (z_multi_h_start[u,t,w]+z_multi_c_start[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    @constraint(H4C, multi_unit_ramp_down_ini[u=1:U_multi, f=1:F, t=1:1, w=1:W],  sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_down[f] + (z_multi_h_stop[u,t,w]+z_multi_c_stop[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    
    
    # Minimum down time (after a cold stop the unit stays in an off-state) and minimum
    # up time (after a hot or cold start the unit stays on).
    # Multi units: forward-looking, capped at T
    @constraint(H4C, multi_min_down_t[u=1:U_multi, t=1:T, w=1:W], sum(z_multi_state[u,q,t1,w] for q in 1:Q, t1 in t:min(t+multi_units[u].min_down_time-1, T) if multi_units[u].states[q]=="off") >= min(multi_units[u].min_down_time, T-t+1) * z_multi_c_stop[u,t,w])

    @constraint(H4C, multi_min_up_t[u=1:U_multi, t=1:T, w=1:W],   sum(z_multi_on[u,t1,w] for t1 in t:min(t+multi_units[u].min_up_time-1, T))   >= min(multi_units[u].min_up_time, T-t+1) * (z_multi_c_start[u,t,w] + z_multi_h_start[u,t,w]))


    # Multi carry-over from previous day
    @constraint(H4C, multi_min_down_t_ini[u=1:U_multi, t=1:T, w=1:W; t <= multi_units[u].min_down_time-1], sum(z_multi_state[u,q,t1,w] for q in 1:Q, t1 in 1:t if multi_units[u].states[q]=="off") >= t * ini_vec[:z_multi_c_stop][u, end-multi_units[u].min_down_time+1+t])

    @constraint(H4C, multi_min_up_t_ini[u=1:U_multi, t=1:T, w=1:W; t <= multi_units[u].min_up_time-1],   sum(z_multi_on[u,t1,w] for t1 in 1:t)   >= t * (ini_vec[:z_multi_c_start][u, end-multi_units[u].min_up_time+1+t] + ini_vec[:z_multi_h_start][u, end-multi_units[u].min_up_time+1+t]))

    # -------------------------------------------------------------------------
    # Segment units
    # The conversion factors depend on the level of a storage (segment_determiner):
    # segment i is active when that storage level lies in [min_state[i], max_state[i]].
    # -------------------------------------------------------------------------
    # The (lagged) input of each carrier is distributed over the segments
    @constraint(H4C, segment_unit_in[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == segment_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == segment_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0)
                                                                   ==sum(x_segment_in[u,i,f,t,w] for i in 1:I))

    # Conversion: the output of carrier f1 equals the input of carrier f multiplied by
    # the conversion factor of the active segment, conv_matrix[i,f,f1]
    @constraint(H4C, segment_balance[u=1:U_segment, f=1:F, f1=1:F, t=1:T, w=1:W], sum(x_segment_in[u,i,f,t,w]*segment_units[u].conv_matrix[i,f,f1] for i in 1:I) -
                                                                                  sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f1] && any(segment_units[u].conv_matrix[:,f,f1] .!= 0))  == 0 )

    
    # Input and output bounds of the active segment; inactive segments have zero input
    @constraint(H4C, segment_unit_in_min[u=1:U_segment,i=1:I, f=1:F, t=1:T, w=1:W], x_segment_in[u,i,f,t,w] >= z_segment_state[u,i,t,w]*segment_units[u].min_input[i,f])
    @constraint(H4C, segment_unit_in_max[u=1:U_segment,i=1:I, f=1:F, t=1:T, w=1:W], x_segment_in[u,i,f,t,w] <= z_segment_state[u,i,t,w]*segment_units[u].max_input[i,f])
    
    
    
    @constraint(H4C, segment_unit_out_min[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f]) >= sum(z_segment_state[u,i,t,w]*segment_units[u].min_output[i,f] for i in 1:I))
    @constraint(H4C, segment_unit_out_max[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f]) <= sum(z_segment_state[u,i,t,w]*segment_units[u].max_output[i,f] for i in 1:I))
    

    # Link between the active segment and the level of the determining storage:
    # min_state <= storage level <= max_state of the active segment. When the unit is
    # off no segment is active; the big-M term (the storage capacity) then relaxes the
    # upper bound to the regular capacity constraint, so the storage need not be empty.
    @constraint(H4C, segment_unit_segment_determiner_min[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w]*segment_units[u].min_state[i] for i in 1:I) <= y[segment_units[u].segment_determiner,t,w])

    @constraint(H4C, segment_unit_segment_determiner_max[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w]*segment_units[u].max_state[i] for i in 1:I) + storages[segment_units[u].segment_determiner].energy_cap*(1 - z_segment_on[u,t,w]) >= y[segment_units[u].segment_determiner,t,w])
                                                                                        

    # Exactly one segment is active when the unit is on, none when it is off
    @constraint(H4C, segment_unit_state_on[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w] for i in 1:I) == z_segment_on[u,t,w])

    
    # Start/stop logic and ramping limits, analogous to the standard units
    @constraint(H4C, segment_unit_start_stop[u=1:U_segment, t=2:T, w=1:W], z_segment_start[u,t,w] - z_segment_stop[u,t,w] == z_segment_on[u,t,w]- z_segment_on[u,t-1,w])
    @constraint(H4C, segment_unit_start_stop_ini[u=1:U_segment, w=1:W],    z_segment_start[u,1,w] - z_segment_stop[u,1,w] == z_segment_on[u,1,w]- ini_vec[:z_segment_on][u,end])

    @constraint(H4C, segment_unit_ss_sum[u=1:U_segment, t=1:T, w=1:W],     z_segment_start[u,t,w] + z_segment_stop[u,t,w] <= 1)

    @constraint(H4C, segment_unit_ramp_up[u=1:U_segment, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_up[f] + z_segment_start[u,t,w]*segment_units[u].min_ramp[f])
    @constraint(H4C, segment_unit_ramp_down[u=1:U_segment, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_down[f] + z_segment_stop[u,t,w]*segment_units[u].min_ramp[f])

    @constraint(H4C, segment_unit_ramp_up_ini[u=1:U_segment, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_up[f] + z_segment_start[u,t,w]*segment_units[u].min_ramp[f])
    @constraint(H4C, segment_unit_ramp_down_ini[u=1:U_segment, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_down[f] + z_segment_stop[u,t,w]*segment_units[u].min_ramp[f])
    

    # Segment units: forward-looking, capped at T
    @constraint(H4C, segment_min_down_t[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_on[u,t1,w] for t1 in t:min(t+segment_units[u].min_down_time-1, T)) <= min(segment_units[u].min_down_time, T-t+1) * (1 - z_segment_stop[u,t,w]))

    @constraint(H4C, segment_min_up_t[u=1:U_segment, t=1:T, w=1:W],   sum(z_segment_on[u,t1,w] for t1 in t:min(t+segment_units[u].min_up_time-1, T))   >= min(segment_units[u].min_up_time, T-t+1) * z_segment_start[u,t,w])

# Segment carry-over from previous day
    @constraint(H4C, segment_min_down_t_ini[u=1:U_segment, t=1:T, w=1:W; t <= segment_units[u].min_down_time-1], sum(z_segment_on[u,t1,w] for t1 in 1:t) <= t * (1 - ini_vec[:z_segment_stop][u, end-segment_units[u].min_down_time+1+t]))

    @constraint(H4C, segment_min_up_t_ini[u=1:U_segment, t=1:T, w=1:W; t <= segment_units[u].min_up_time-1],   sum(z_segment_on[u,t1,w] for t1 in 1:t)   >= t * ini_vec[:z_segment_start][u, end-segment_units[u].min_up_time+1+t])

    # -------------------------------------------------------------------------
    # Line capacities
    # -------------------------------------------------------------------------
    @constraint(H4C, line_min_flow[a=1:A, t=1:T, w=1:W], x[a,t,w] >= lines[a].min_cap)
    @constraint(H4C, line_max_flow[a=1:A, t=1:T, w=1:W], x[a,t,w] <= lines[a].max_cap)

    # -------------------------------------------------------------------------
    # Non-anticipativity: the commitment decisions in the here-and-now time steps
    # (t <= T_hn) are made before the scenario is known and are therefore equal in
    # all scenarios (enforced by chaining scenario w-1 to w)
    # -------------------------------------------------------------------------
    if W > 1
        @constraint(H4C, units_sequential[u=1:U, t=1:T_hn, w=2:W],                                  z[u,t,w-1]             == z[u,t,w])
        @constraint(H4C, transport_sequential[u=1:U_trans, r=1:R, t=1:T_hn, w=2:W],                 z_transport[u,r,t,w-1] == z_transport[u,r,t,w])
        @constraint(H4C, multi_unit_sequential[u=1:U_multi, t=1:T_hn, w=2:W],                       z_multi_on[u,t,w-1]    == z_multi_on[u,t,w])
        @constraint(H4C, segment_unit_sequential[u=1:U_segment, t=1:T_hn, w=2:W], z_segment_on[u,t,w-1]    == z_segment_on[u,t,w])
        @constraint(H4C, cg_unit_sequential[u=1:U_CG, t=1:T_hn, w=2:W],                             z_cg[u,t,w-1]          == z_cg[u,t,w])
    end
 


    # -------------------------------------------------------------------------
    # Solve
    # -------------------------------------------------------------------------
    # Set time limit if provided (soft limit with Gurobi, hard limit with other solvers)
    apply_time_limit!(H4C, time_limit)

    #set_optimizer_attribute(H4C, "MIPGap", 0.2)

    #set_optimizer_attribute(H4C, "DualReductions", 0)
    
    # Tight tolerances: with looser (default) integrality tolerances, "almost zero"
    # binaries can pass non-negligible flows through the big-M constraints.
    # The parameter names are solver-specific; other solvers keep their defaults.
    if solver_name(H4C) == "Gurobi"
        set_optimizer_attribute(H4C, "IntFeasTol", 1e-7)       # default 1e-5
        set_optimizer_attribute(H4C, "FeasibilityTol", 1e-8)   # default 1e-6
    elseif solver_name(H4C) == "HiGHS"
        set_optimizer_attribute(H4C, "mip_feasibility_tolerance", 1e-7)      # default 1e-6
        set_optimizer_attribute(H4C, "primal_feasibility_tolerance", 1e-8)   # default 1e-7
    end

    t_start_opt = time()
    optimize!(H4C)
    t_end = time()
    solve_time = t_end - t_start_opt

    # Capture MIP gap (relative gap between best bound and incumbent)
    mip_gap = get_mip_gap(H4C)

    # No feasible solution found (infeasible, or interrupted before the first incumbent):
    # return zero arrays of the correct size so that the calling code can continue
    if !has_values(H4C)
        return Dict(
            :x               => zeros(size(x)),
            :y               => zeros(size(y)),
            :z               => zeros(size(z)),
            :z_start         => zeros(size(z_start)),
            :z_stop          => zeros(size(z_stop)),
            :alpha           => zeros(size(alpha)),
            :z_cg            => zeros(size(z_cg)),
            :z_cg_start      => zeros(size(z_cg_start)),
            :z_cg_stop       => zeros(size(z_cg_stop)),
            :x_multi_main    => zeros(size(x_multi_main)),
            :z_multi_on      => zeros(size(z_multi_on)),
            :z_multi_h_start => zeros(size(z_multi_h_start)),
            :z_multi_c_start => zeros(size(z_multi_c_start)),
            :z_multi_h_stop  => zeros(size(z_multi_h_stop)),
            :z_multi_c_stop  => zeros(size(z_multi_c_stop)),
            :z_multi_state   => zeros(size(z_multi_state)),
            :x_segment_in    => zeros(size(x_segment_in)),
            :z_segment_on    => zeros(size(z_segment_on)),
            :z_segment_start => zeros(size(z_segment_start)),
            :z_segment_stop  => zeros(size(z_segment_stop)),
            :z_segment_state => zeros(size(z_segment_state)),
            :z_transport     => zeros(size(z_transport)),
            :v_up            => zeros(size(v_up)),
            :v_down          => zeros(size(v_down)),
            :status          => termination_status(H4C),
            :objective       => [NaN],
            :objective_hn    => [NaN],
            :solve_time      => [solve_time],
            :mip_gap         => [NaN]
        )
    end

    
    # -------------------------------------------------------------------------
    # Expected objective over the here-and-now time steps only (t <= T_hn). In a
    # rolling-horizon simulation this is the part of the cost that is actually
    # realised. It is evaluated per unit type, since empty sums over absent unit
    # types cannot be passed to value.().
    # -------------------------------------------------------------------------
    if !isempty(multi_units)
        multi_unit_obj =value.(sum(pi[w]*(sum(multi_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_multi, f in 1:F, t in 1:T_hn, a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f]) +
                                           sum(z_multi_c_stop[u,t,w]*multi_units[u].start_stop_cost[2] for u in 1:U_multi, t in 1:T_hn) + 
                                           sum(z_multi_h_stop[u,t,w]*multi_units[u].start_stop_cost[1] for u in 1:U_multi, t in 1:T_hn)) for w in 1:W))
    else
        multi_unit_obj = 0
    end

    if !isempty(cg_units)
        cg_unit_obj = value.(sum(pi[w]*(sum(cg_units[u].start_stop_cost*z_cg_stop[u,t,w] for u in 1:U_CG) +
                         sum(cg_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_CG, f in 1:F, a in 1:A if lines[a].from == cg_units[u].node && lines[a].carrier == carriers[f])) for t in 1:T_hn, w in 1:W))
    else
        cg_unit_obj = 0
    end

    if !isempty(segment_units)
        segment_unit_obj = value.(sum(pi[w]*(sum(segment_units[u].start_stop_cost*z_segment_stop[u,t,w] for u in 1:U_segment) +
                         sum(segment_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_segment, f in 1:F, a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f])) for t in 1:T_hn, w in 1:W))
    else
        segment_unit_obj = 0
    end

    if !isempty(transport_units)
        transport_unit_obj = value.(sum(pi[w]*(sum(z_transport[u,r,t,w]*(transport_units[u].cost_fixed + transport_units[u].cost_distance*lines[route_lines[u,r]].distance + transport_units[u].cost_time*tau_routes[u,r]) for u in 1:U_trans, r in 1:R if route_lines[u,r] > 0)) for t in 1:T_hn, w in 1:W))
    else
        transport_unit_obj = 0
    end

    # Sources, standard units and demand revenue, plus the unit-type terms from above
    objective_hn = (value.(sum(pi[w]*(sum(lines[a].cost*x[a,t,w] for a in 1:A) +
                        sum(sources[e].price[t,w]*x[a,t,w] for e in 1:E, a in 1:A if lines[a].from == sources[e].node) +
                        sum(units[u].start_stop_cost*z_stop[u,t,w] for u in 1:U)+
                        sum(units[u].cost_operating[f]*x[a,t,w] for u in 1:U, f in 1:F, a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) + -
                        sum(demands[d].price[t,w]*x[a,t,w] for d in 1:D, a in 1:A if lines[a].to == demands[d].node)) for t in 1:T_hn, w in 1:W)) +
                        multi_unit_obj + cg_unit_obj + segment_unit_obj + transport_unit_obj)




    # Collect the solution. Scalars are wrapped in one-element vectors.
    results = Dict(
        :x               => value.(x),
        :y               => value.(y),
        :z               => value.(z),
        :z_start         => value.(z_start),
        :z_stop          => value.(z_stop),
        :alpha           => value.(alpha),
        :z_cg            => value.(z_cg),
        :z_cg_start      => value.(z_cg_start),
        :z_cg_stop       => value.(z_cg_stop),
        :x_multi_main    => value.(x_multi_main),
        :z_multi_on      => value.(z_multi_on),
        :z_multi_h_start => value.(z_multi_h_start),
        :z_multi_c_start => value.(z_multi_c_start),
        :z_multi_h_stop  => value.(z_multi_h_stop),
        :z_multi_c_stop  => value.(z_multi_c_stop),
        :z_multi_state   => value.(z_multi_state),
        :x_segment_in => value.(x_segment_in),
        :z_segment_on => value.(z_segment_on),
        :z_segment_start => value.(z_segment_start),
        :z_segment_stop => value.(z_segment_stop),
        :z_segment_state => value.(z_segment_state),
        :z_transport     => value.(z_transport),
        :v_up            => value.(v_up),
        :v_down          => value.(v_down),
        :status          => termination_status(H4C),
        :objective       => [objective_value(H4C)],
        :objective_hn    => [objective_hn],
        :solve_time      => [solve_time],
        :mip_gap         => [mip_gap]
    )



    return results
end
