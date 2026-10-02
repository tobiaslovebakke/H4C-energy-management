

# =============================================================================
# H4C_preprocessing.jl
#
# Reads the network from process_data/ and prepares everything the models need:
#   1. loads all components of the network (lines, units, storages, ...) with
#      the prep files;
#   2. computes the set sizes (number of lines, units, scenarios, ...) and the
#      transport routes;
#   3. builds the default initial state `ini_vec`: the state at the end of the
#      (fictitious) previous horizon, from which the first optimisation starts.
#
# All results are defined as global variables, which are used by the main script
# and by the models.
#
# Requires the following globals, set in the main script before this file is
# included: Scenarios, T_opti, T_considered, T_hn and the big-M constants
# (M_unit, M_sources, M_demand, ...).
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Load the components of the network
# line_prep.jl must come first: it loads the packages and defines `carriers`,
# `carrier_matrix` and the helper functions used by the other prep files.
# -----------------------------------------------------------------------------
include(joinpath(@__DIR__, "line_prep.jl"))
include(joinpath(@__DIR__, "unit_prep.jl"))
include(joinpath(@__DIR__, "cg_unit_prep.jl"))
include(joinpath(@__DIR__, "transport_unit_prep.jl"))
include(joinpath(@__DIR__, "storage_prep.jl"))
include(joinpath(@__DIR__, "demand_prep.jl"))
include(joinpath(@__DIR__, "source_prep.jl"))
include(joinpath(@__DIR__, "multi_stage_unit_prep.jl"))
include(joinpath(@__DIR__, "segment_unit_prep.jl"))

"""
    append_results!(results, new_results)

Append the entries of `new_results` to those of `results` with the same key
(vertical concatenation) and return `results`. Keys that are not yet in `results`
are added. Useful to collect the results of successive iterations of a
rolling-horizon simulation.
"""
function append_results!(results::Dict, new_results::Dict)
    for (k, v) in new_results
        if haskey(results, k)
            results[k] = vcat(results[k], v)   # append vectors
        else
            results[k] = v                     # first entry
        end
    end
    return results
end




using JuMP
using Dates

# The solver package and `optimizer` are loaded in the main script.


# -----------------------------------------------------------------------------
# 2. Set sizes
# -----------------------------------------------------------------------------
W          = Scenarios
U          = size(units,1)
U_CG       = length(cg_units)
U_trans    = length(transport_units)
U_multi    = length(multi_units)
U_segment = length(segment_units)
A          = size(lines,1)
T          = T_considered
E          = size(sources,1)
S          = size(storages,1)
D          = size(demands,1)
D_nf       = length(demands_nf)
D_transfer = length(demands_transferable)
F          = size(carriers,1)
# Q: maximum number of states of the multi-state units; G: maximum number of
# extreme points of the CG units
if !isempty(multi_units)
        state_vec = getfield.(multi_units, :states)
        Q    = maximum(length.(state_vec))
    else
        Q = 0
    end
if !isempty(cg_units)
    G    = maximum(size.(extreme_cgs, 2))
else
    G = 0
end

# I: maximum number of segments of the segment units (0 if there are none)
if !isempty(segment_units)
    I = maximum(getfield.(segment_units, :num_segments))
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

# Example of a vector of index tuples, the format used to select first-stage
# decisions (idxs_first_stage) in the rolling-horizon template. The loop has no effect.
idxs = collect((u,t,w) for u in [1,3], t in 1:24, w in 1:2)
for I in idxs
    #println(x[I...])   # this works
end



# -----------------------------------------------------------------------------
# 3. Default initial state
# The models need the state at the end of the previous horizon, e.g. which units
# were on, the storage levels and the flows still under way on lines with a lag.
# For the first optimisation there is no previous horizon, so a default state is
# used: all units off, no flows, no demand shifts and all storages at their
# initial_level.
# -----------------------------------------------------------------------------

# Initial flows, commitments and transport trips per component. These are not
# used by the current models, which take the initial state from `ini_vec` below.
x_ini = zeros(A,L)


z_ini = zeros(U)
z_cg_ini = zeros(U_CG)

z_transport_ini = zeros(U_trans,R, tau_max)

# Upward and downward demand shifts of the previous horizon [demand, time step].
# The models read these as globals (not from ini_vec); zero means no earlier shifts.
v_up_ini   = zeros(D_transfer,T)
v_down_ini = zeros(D_transfer,T)

# Multi-state units start in their first state (the first entry of "states" in
# their JSON file) [unit, state, time step]
z_multi_state_ini        = zeros(U_multi,Q,T_hn)
z_multi_state_ini[:,1,:] = ones(U_multi,T_hn)

# Segment units start in the segment that matches the initial_level of the storage
# that determines their segment [unit, segment, time step]
z_segment_state_ini = zeros(U_segment,I,T_hn)

for u in 1:U_segment
    segment_determiner = segment_units[u].segment_determiner
    ini_state = storages[segment_determiner].initial_level
    state_carrier = storages[segment_determiner].carrier
    carrier = findfirst(==(state_carrier), carriers)
    for i in 1:segment_units[u].num_segments
        if ini_state>=segment_units[u].min_state[i] && ini_state<=segment_units[u].max_state[i]
            z_segment_state_ini[u,i,:] = ones(T_hn)
        end
    end
end

# The initial state passed to the models. Each entry has the same indices as the
# corresponding model variable, with T_hn time steps; the last column (`end`) is
# the time step directly before t = 1. The models look back from there for line
# lags and minimum up/down times, so T_hn must be at least as long as the longest
# lag and minimum up/down time. In a rolling-horizon simulation, ini_vec is
# replaced by the realised results of the previous iteration.
ini_vec = results = Dict(
        :x               => zeros(A,T_hn),
        :y               => getfield.(storages,:initial_level) .* ones(1, T_hn),
        :z               => zeros(U,T_hn),
        :z_start         => zeros(U,T_hn),
        :z_stop          => zeros(U,T_hn),
        :alpha           => zeros(U_CG,G,T_hn),
        :z_cg            => zeros(U_CG,T_hn),
        :z_cg_start      => zeros(U_CG,T_hn),
        :z_cg_stop       => zeros(U_CG,T_hn),
        :z_transport     => zeros(U_trans,length(route_lines),T_hn),
        :v_up            => zeros(D_transfer,T_hn),
        :v_down          => zeros(D_transfer,T_hn),
        :x_multi_main    => zeros(U_multi,Q,T_hn),
        :z_multi_on      => zeros(U_multi,T_hn),
        :z_multi_c_start => zeros(U_multi, T_hn),
        :z_multi_c_stop  => zeros(U_multi, T_hn),
        :z_multi_h_start => zeros(U_multi, T_hn),
        :z_multi_h_stop  => zeros(U_multi, T_hn),
        :z_multi_state   => z_multi_state_ini,
        :x_segment_in => zeros(U_segment,T_hn),
        :z_segment_on => zeros(U_segment,T_hn),
        :z_segment_start => zeros(U_segment,T_hn),
        :z_segment_stop => zeros(U_segment,T_hn),
        :z_segment_state => z_segment_state_ini,
    )
