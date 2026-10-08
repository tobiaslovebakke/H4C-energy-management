# =============================================================================
# EM_in_H4C_model_main_RH_template.jl
#
# Template for a rolling-horizon (RH) simulation with the H4C model. It sets up
# everything that is needed, but the rolling-horizon loop itself is left to the
# user, because it depends on how the forecasts and realised data are obtained.
# The suggested steps of the loop are written out as comments at the end.
#
# In each iteration of a rolling-horizon simulation:
#   1. the stochastic model (h4c_stochastic) is solved over T_opti time steps with
#      the forecast scenarios;
#   2. its first-stage (here-and-now) decisions for the first T_hn time steps are
#      fixed, and the realisation model (h4c_realisation) is solved with the
#      realised data, to evaluate what actually happens;
#   3. the realised state at the end of the T_hn time steps becomes the initial
#      state of the next iteration, and the horizon moves T_hn time steps forward.
#
# Input:  the network description in process_data/ (one folder per component
#         type) and the time series in time_series_data/.
# =============================================================================

using Pkg
Pkg.activate(@__DIR__)

# ============================== USER SETTINGS ==============================
# Name of the run; used in the names of the result files
simulation_name = "h4c_rh_example"

# Horizon and scenarios
T_opti          = 168                            # Number of time steps in the optimisation horizon
Scenarios       = 3                              # Number of scenarios
probabilities   = fill(1/Scenarios, Scenarios)   # Probability of each scenario, e.g. [0.5, 0.3, 0.2]

# Solver settings
time_limit      = 300                            # Time limit per solve in seconds (nothing = no limit)
threads         = 0                              # Number of threads (0 = solver default)
nodes           = 8                              # Memory (GB) after which nodes are written to disk (Gurobi only)

# Solver: any MILP solver supported by JuMP can be used. Load its package and set
# `optimizer` to its Optimizer. The package must be installed in this project,
# e.g. with  using Pkg; Pkg.add("HiGHS")
#
# Default: Gurobi (commercial; free licences for academics)
using Gurobi
optimizer = Gurobi.Optimizer

# Free alternative: HiGHS
# using HiGHS
# optimizer = HiGHS.Optimizer
# ===========================================================================

# Check the scenario probabilities
length(probabilities) == Scenarios ||
    error("probabilities has $(length(probabilities)) values, but Scenarios = $(Scenarios).")
all(probabilities .>= 0) || error("probabilities must not be negative.")
isapprox(sum(probabilities), 1; atol=1e-6) ||
    error("probabilities must sum to 1, but they sum to $(sum(probabilities)).")

T_considered = T_opti   # Number of time steps read from the input data
T_hn = 24               # Number of here-and-now time steps (= step size of the rolling horizon)

# Big-M constants
M          = 10000
M_demand   = 500
M_unit     = M
M_lines    = M
M_sources  = M
M_storages = M

# Read the network and build the default initial state (ini_vec)
include(joinpath(@__DIR__, "H4C_preprocessing.jl"))
include(joinpath(@__DIR__, "EM_in_H4C_model_stochastic.jl"))
include(joinpath(@__DIR__, "EM_in_H4C_model_realisation.jl"))


# =============================================================================
# First-stage decisions that are fixed in the realisation model
# =============================================================================
# For each variable, the indices whose value is taken over from the stochastic
# solution: the commitment decisions (on/off status and transport trips) of all
# units in the here-and-now time steps t = 1, ..., T_hn, in all scenarios.
# The realisation model fixes these with lock_variables!. In addition, it fixes
# the flows taken from sources with here_and_now = true (see
# EM_in_H4C_model_realisation.jl).
#
# To fix more or fewer decisions, add or remove entries. The keys must be names of
# variables in the realisation model and each index tuple must have the same
# indices as that variable.
idxs_first_stage = Dict(
    :z            => [(u,t,w)   for u in 1:U,         t in 1:T_hn, w in 1:W],               # Standard units on/off
    :z_transport  => [(u,r,t,w) for u in 1:U_trans,   r in 1:R, t in 1:T_hn, w in 1:W],     # Transport trips per route
    :z_cg         => [(u,t,w)   for u in 1:U_CG,      t in 1:T_hn, w in 1:W],               # CG units on/off
    :z_multi_on   => [(u,t,w)   for u in 1:U_multi,   t in 1:T_hn, w in 1:W],               # Multi-state units on/off
    :z_segment_on => [(u,t,w)   for u in 1:U_segment, t in 1:T_hn, w in 1:W],               # Segment units on/off
)


# =============================================================================
# Rolling-horizon loop (to be written by the user)
# =============================================================================
# Suggested steps for each iteration k = 1, ..., n_iterations:
#
# 1. Update the forecasts for this iteration. Each time series is a
#    [T_opti, Scenarios] matrix, e.g.
#        sources[1].output = <forecast scenarios of source 1>
#        sources[3].price  = <forecast price scenarios>
#        demands[2].demand = <forecast demand scenarios>
#    If the scenario probabilities change per iteration, update `probabilities`.
#
# 2. Solve the stochastic model:
#        stoc_res = h4c_stochastic(lines, sources, units, cg_units, transport_units,
#                                  multi_units, segment_units, storages, demands,
#                                  demands_nf, demands_transferable, ini_vec,
#                                  probabilities, T_opti, T_hn;
#                                  optimizer=optimizer, threads=threads, nodes=nodes,
#                                  time_limit=time_limit)
#    If no solution was found, isnan(stoc_res[:objective_hn][1]) is true; decide
#    whether to stop or to skip the realisation of this iteration.
#
# 3. Take the first-stage values from the stochastic solution:
#        first_stage_values = Dict(k => v for (k, v) in stoc_res if k ∉ (:status, :objective))
#
# 4. Build the realised data: copies of the sources and demands in which the first
#    T_hn time steps of every scenario column are replaced by the realised values.
#    Use deepcopy, so that the forecasts in `sources` and `demands` are not
#    overwritten:
#        sources_real = deepcopy(sources)
#        for w in 1:W
#            sources_real[1].output[1:T_hn, w] = <realised output of source 1>
#        end
#
# 5. Solve the realisation model with the first-stage decisions fixed:
#        real_res_full, real_res = h4c_realisation(lines, sources_real, units, cg_units,
#                                       transport_units, multi_units, segment_units,
#                                       storages, demands_real, demands_nf,
#                                       demands_transferable, ini_vec, probabilities,
#                                       first_stage_values, idxs_first_stage,
#                                       T_opti, T_hn;
#                                       optimizer=optimizer, threads=threads,
#                                       nodes=nodes, time_limit=time_limit)
#    real_res holds the realised decisions of the first T_hn time steps (scenario 1),
#    real_res_full the solution over the whole horizon.
#
# 6. Carry the realised state over to the next iteration:
#        ini_vec = Dict(k => v for (k, v) in real_res if k ∉ (:status, :objective, :solve_time, :mip_gap))
#    Demand shifts of transferable demands are balanced within periods of
#    flex_interval time steps and are not carried over; choose T_hn as a multiple of
#    flex_interval so that these periods line up from one iteration to the next.
#
# 7. Store the results of this iteration, e.g. append real_res to a results
#    collection and write it to Results/ (see EM_in_H4C_model_main.jl for an
#    example of writing results to CSV files). Writing after every iteration
#    keeps the results of long runs if the run is interrupted.
#
# 8. Remove the node files Gurobi may have written:
#        for dir in ["stochastic_$(simulation_name)", "realisation_$(simulation_name)"]
#            rm(joinpath(@__DIR__, "Nodefiles", dir); recursive=true, force=true)
#        end
#
# Then move the forecasts and realised data T_hn time steps forward and repeat.
