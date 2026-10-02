# =============================================================================
# EM_in_H4C_model_main.jl
#
# Runs the two-stage stochastic H4C model once and saves the results.
#
# Usage: adjust the USER SETTINGS below and run
#     julia EM_in_H4C_model_main.jl
# or include("EM_in_H4C_model_main.jl") from the Julia REPL.
#
# Input:  the network description in process_data/ (one folder per component
#         type) and the time series in time_series_data/.
# Output: Results/<simulation_name>_summary.csv with the solve status, objective,
#         solve time and MIP gap, and one file Results/<simulation_name>_<variable>.csv
#         per decision variable.
#
# The model starts from a default initial state: all units off and all storages at
# their initial_level (see H4C_preprocessing.jl).
# =============================================================================

using Pkg
Pkg.activate(@__DIR__)

# ============================== USER SETTINGS ==============================
# Name of the run; used in the names of the result files
simulation_name = "h4c_example"

# Horizon and scenarios
T_opti          = 168                            # Number of time steps in the optimisation horizon
Scenarios       = 3                              # Number of scenarios
probabilities   = fill(1/Scenarios, Scenarios)   # Probability of each scenario, e.g. [0.5, 0.3, 0.2]

# Solver settings
time_limit      = 300                            # Time limit in seconds (nothing = no limit)
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
T_hn = 24               # Number of here-and-now time steps

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


# =============================================================================
# Solve the stochastic model
# =============================================================================
stoc_res = h4c_stochastic(
    lines,
    sources,
    units,
    cg_units,
    transport_units,
    multi_units,
    segment_units,
    storages,
    demands,
    demands_nf,
    demands_transferable,
    ini_vec,         # Initial state, built in H4C_preprocessing.jl
    probabilities,
    T_opti, T_hn;
    optimizer  = optimizer,
    threads    = threads,
    nodes      = nodes,
    time_limit = time_limit)

# Remove the node files Gurobi may have written during the solve
rm(joinpath(@__DIR__, "Nodefiles", "stochastic_$(simulation_name)"); recursive=true, force=true)


# =============================================================================
# Save the results
# =============================================================================
"""
    result_table(values, labels)

Convert the solution of one decision variable to a table. `values` is indexed as in
the model, with time step and scenario as the last two indices. Each row of the
table is one (scenario, time step) combination and each column one element of the
variable. The column names are taken from `labels` (one name per value of the
first index), followed by the remaining indices, e.g. "chp_2" for extreme point 2
of the unit "chp".
"""
function result_table(values, labels)
    n_t, n_w = size(values)[end-1:end]
    table = DataFrame(Scenario = repeat(1:n_w, inner=n_t), Time = repeat(1:n_t, outer=n_w))
    for idx in CartesianIndices(size(values)[1:end-2])
        idx = Tuple(idx)
        column = join((string(labels[idx[1]]), string.(idx[2:end])...), "_")
        # Make the column name unique if two elements have the same name
        while column in names(table)
            column *= "_$(idx[1])"
        end
        table[!, column] = vec(values[idx..., :, :])
    end
    return table
end

# Names used as column headers per variable. Additional indices are appended to
# the name: route (z_transport), extreme point (alpha), state (x_multi_main,
# z_multi_state) and segment and carrier (x_segment_in, z_segment_state).
line_names        = getfield.(lines, :name)
storage_names     = getfield.(storages, :name)
unit_names        = getfield.(units, :name)
cg_unit_names     = getfield.(cg_units, :name)
transport_names   = getfield.(transport_units, :name)
multi_unit_names  = getfield.(multi_units, :name)
segment_names     = getfield.(segment_units, :name)
transferable_names = getfield.(demands_transferable, :name)

result_labels = Dict(
    :x               => line_names,
    :y               => storage_names,
    :z               => unit_names,
    :z_start         => unit_names,
    :z_stop          => unit_names,
    :alpha           => cg_unit_names,
    :z_cg            => cg_unit_names,
    :z_cg_start      => cg_unit_names,
    :z_cg_stop       => cg_unit_names,
    :z_transport     => transport_names,
    :x_multi_main    => multi_unit_names,
    :z_multi_on      => multi_unit_names,
    :z_multi_h_start => multi_unit_names,
    :z_multi_c_start => multi_unit_names,
    :z_multi_h_stop  => multi_unit_names,
    :z_multi_c_stop  => multi_unit_names,
    :z_multi_state   => multi_unit_names,
    :x_segment_in    => segment_names,
    :z_segment_on    => segment_names,
    :z_segment_start => segment_names,
    :z_segment_stop  => segment_names,
    :z_segment_state => segment_names,
    :v_up            => transferable_names,
    :v_down          => transferable_names,
)

results_dir = joinpath(@__DIR__, "Results")
mkpath(results_dir)

# Summary of the solve
summary_table = DataFrame(
    status       = [string(stoc_res[:status])],
    objective    = stoc_res[:objective],
    objective_hn = stoc_res[:objective_hn],
    solve_time   = stoc_res[:solve_time],
    mip_gap      = stoc_res[:mip_gap],
)
CSV.write(joinpath(results_dir, "$(simulation_name)_summary.csv"), summary_table)

# One file per decision variable (only if a solution was found)
if isnan(stoc_res[:objective][1])
    @warn "No feasible solution found (status: $(stoc_res[:status])). Only the summary is saved."
else
    for (variable, labels) in result_labels
        values = stoc_res[variable]
        isempty(values) && continue   # Component type not present in the network
        CSV.write(joinpath(results_dir, "$(simulation_name)_$(variable).csv"), result_table(values, labels))
    end
end

println()
println("Status:      $(stoc_res[:status])")
println("Objective:   $(stoc_res[:objective][1])")
println("Solve time:  $(round(stoc_res[:solve_time][1]; digits=1)) s")
println("MIP gap:     $(stoc_res[:mip_gap][1])")
println("Results saved in $(results_dir)")
