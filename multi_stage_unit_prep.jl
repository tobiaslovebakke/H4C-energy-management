# =============================================================================
# multi_stage_unit_prep.jl
#
# Reads the multi-state units from the JSON files in process_data/multi_units.
# A multi-state unit is in exactly one of its states in every time step. Each
# state is of the type "off", "standby" or "on" and has its own operating range.
# Within a state, the input and output of every carrier are affine functions of
# the main output of the unit (see `a_input`, `b_input`, `a_output`, `b_output`).
#
# Requires line_prep.jl (`carriers`, `carrier_matrix`) and the global `M_unit`
# (large number, used as "no limit" for the ramp rates).
# Defines `multi_units` and, if there are multi-state units, `Q`.
#
# JSON fields of a multi-state unit (one file per unit)
#   required: "module" (= "multi_unit"), "name", "node", "main_output",
#             "num_states", "states", "cost_operating", "min_input", "max_input",
#             "min_output", "max_output"
#   optional: "start_stop_cost" (default [0, 0]), "min_down_time" (0),
#             "min_up_time" (0), "start_up_time" ([0, 0]), "ramp_up" (M_unit),
#             "ramp_down" (M_unit)
# "main_output" is the name of a carrier and "states" a vector with the type of
# each state, e.g. ["off", "standby", "on"]. "min_input", "max_input", "min_output"
# and "max_output" are objects with, per carrier, a vector with one value per state.
# "cost_operating", "ramp_up" and "ramp_down" are objects with one value per carrier.
# =============================================================================
#using JSON
mutable struct Multi_Unit
    name::String                     # Unit Name
    node::Int64                      # Unit node
    main_output::Vector{Int}         # One-hot vector over the carriers that marks the main output
    start_stop_cost::Vector{Float64} # Cost of one start/stop cycle [hot (on <-> standby), cold (on <-> off)], charged at the stop
    min_down_time::Int64             # Minimum down time 
    min_up_time::Int64               # Minimum up time
    start_up_time::Vector{Float64}   # Start up time for off->on and standby->on
    num_states::Int64                # Number of states
    states::Vector{String}           # vector of states, each state belongs to ["off", "standby", "on"]
    cost_operating::Vector{Float64}  # Per unit operating cost
    a_input::Array{Float64, 2}       # Slope: input of each carrier per unit of main output [state, carrier]
    a_output::Array{Float64, 2}      # Slope: output of each carrier per unit of main output [state, carrier] 
    b_input::Array{Float64, 2}       # Intercept: constant part of each carrier, independent of the main output [state, carrier]
    b_output::Array{Float64, 2}      # Intercept: constant part of each carrier, independent of the main output [state, carrier]
    min_input::Matrix{Float64}       # Minimum input vector
    max_input::Matrix{Float64}       # Maximum input vector
    min_output::Matrix{Float64}      # Minimum output vector
    max_output::Matrix{Float64}      # Maximum output vector,
    ramp_up::Vector{Float64}         # Ramp up for each energy carrier
    ramp_down::Vector{Float64}       # Ramp down for each energy carrier
end

"""
    onehot(label, labels, labels_name, type_name)

Return a vector with a 1 at the position of `label` in `labels` and 0 elsewhere
(not case-sensitive). `labels_name` and `type_name` are only used in the error
message when `label` is not found.
"""
function onehot(label::String, labels::Vector{String}, labels_name::String, type_name::String)
    idx = findall(x -> lowercase(x) == lowercase(label), labels)
    if isempty(idx)
        error("$(type_name) '$label' not found in $(labels_name) vector")
    end
    hot = zeros(Int, length(labels))   # or use Bool if you prefer
    hot[idx] .= 1
    return hot
end


"""
    parse_multi_unit(json_dict, carrier_matrix)

Check that `json_dict` (the content of one JSON file) describes a multi-state unit,
fill in the default values of the optional fields, compute the affine input/output
relations of each state and return the `Multi_Unit`.
"""
function parse_multi_unit(json_dict::Dict{String, Any}, carrier_matrix::Matrix{String})
    # Check for required fields
    required_fields = ["module", "name", "node", "main_output", "num_states", "states", "cost_operating", "min_input", "max_input", "min_output", "max_output"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "multi_unit"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'multi_unit'."))
    end
    #println("carrier check")
    #print(carrier_matrix)
    # Extract required and optional fields
    name        = json_dict["name"]
    node        = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    num_states  = json_dict["num_states"]
    states      = json_dict["states"]
    main_output = onehot(json_dict["main_output"],carriers,"carriers","Main output")

    if !(length(states) == num_states)
        throw(ArgumentError("Length of states and num_states differ, states: $(length(states)), num_states: $(num_states)."))
    end


    N_carriers          = size(carrier_matrix, 1)  # Use the size of the carrier_matrix
    start_stop_cost     = get(json_dict, "start_stop_cost", zeros(2))
    min_down_time       = get(json_dict, "min_down_time", 0)
    min_up_time         = get(json_dict, "min_up_time", 0)
    start_up_time       = get(json_dict, "start_up_time", zeros(2))

    if !(length(start_stop_cost)==2)
        println("Start Stop cost is not properly defined (either not numbers or only defined for one) for both off/on and for standby/on. Set to 0 for both as default")
        start_stop_cost = zeros(2)
    end
    
    if !(start_up_time isa Vector{Float64})
        println("Start up time is not properly defined (either not numbers or only defined for one) for both off/on and for standby/on. Set to 0 for both as default")
        start_up_time = zeros(2)
    end

    # Convert the carrier-dependent fields to vectors in the order of `carriers`, and
    # the state-dependent bounds to [state, carrier] matrices. Default: 0, and M_unit
    # (no limit) for the ramp rates.
    cost_operating      = zeros(size(carriers,1))
    min_input           = zeros(num_states, size(carriers,1))
    max_input           = zeros(num_states, size(carriers,1))
    min_output          = zeros(num_states, size(carriers,1))
    max_output          = zeros(num_states, size(carriers,1))
    ramp_up             = fill(M_unit, length(carriers))
    ramp_down           = fill(M_unit, length(carriers))

    for c in 1:size(carriers,1)
        if haskey(json_dict["cost_operating"], carriers[c])
            cost_operating[c] = json_dict["cost_operating"][carriers[c]]
        end
        if haskey(json_dict, "ramp_up")
            if haskey(json_dict["ramp_up"], carriers[c])
                ramp_up[c] = json_dict["ramp_up"][carriers[c]]
            end
        end
        if haskey(json_dict, "ramp_down")
            if haskey(json_dict["ramp_down"], carriers[c])
                ramp_down[c] = json_dict["ramp_down"][carriers[c]]
            end
        end
        for s in 1:num_states
            if haskey(json_dict["min_input"], carriers[c])
                min_input[s,c] = json_dict["min_input"][carriers[c]][s]
            end
            if haskey(json_dict["max_input"], carriers[c])
                max_input[s,c] = json_dict["max_input"][carriers[c]][s]
            end
            if haskey(json_dict["min_output"], carriers[c])
                min_output[s,c] = json_dict["min_output"][carriers[c]][s]
            end
            if haskey(json_dict["max_output"], carriers[c])
                max_output[s,c] = json_dict["max_output"][carriers[c]][s]
            end
        end
    end




    # Affine input/output relations per state. With x the main output of the unit,
    # the input and the output of carrier i in state q are
    #     input_i  = a_input[q,i]  * x + b_input[q,i]
    #     output_i = a_output[q,i] * x + b_output[q,i]
    # The line is drawn through the minimum-load and the maximum-load point of the
    # state: a is the slope between the two points and b the intercept. States in
    # which the main output has no range (e.g. off) keep a = b = 0.
    a_input  = zeros(Float64, num_states, N_carriers)
    a_output = zeros(Float64, num_states, N_carriers)
    b_input  = zeros(Float64, num_states, N_carriers)
    b_output = zeros(Float64, num_states, N_carriers)

    main_max_output_vec = max_output[:,findfirst(==(1), main_output)]
    main_min_output_vec = min_output[:,findfirst(==(1), main_output)]

    for q in 1:num_states
        for i in 1:N_carriers
            c = carriers[i]
            if (main_max_output_vec[q]-main_min_output_vec[q]) !=0
                a_input[q,i]  = (max_input[q,i] -min_input[q,i])/(main_max_output_vec[q]-main_min_output_vec[q])
                a_output[q,i] = (max_output[q,i]-min_output[q,i])/(main_max_output_vec[q]-main_min_output_vec[q])
                b_output[q,i] = max_output[q,i] - a_output[q,i]*main_max_output_vec[q]
                b_input[q,i]  = max_input[q,i]  - a_input[q,i]*main_max_output_vec[q]
            end
            # In standby there is no main output, so the standby consumption is a constant
            if states[q]=="standby" && min_input[q,i]!=0
                b_input[q,i] = min_input[q,i]
            end
        end
    end


    # Create and return the Unit instance
    return Multi_Unit(name, node,main_output, start_stop_cost, min_down_time, min_up_time, start_up_time, num_states, states, cost_operating, a_input, a_output, b_input, b_output, min_input, max_input, min_output, max_output, ramp_up, ramp_down)
end


"""
    load_multi_units_from_folder(folder_path, carrier_matrix)

Read all JSON files in `folder_path` and return them as a vector of `Multi_Unit`s.
"""
function load_multi_units_from_folder(folder_path::String, carrier_matrix::Matrix{String})
    units = Vector{Multi_Unit}()  # Initialize an empty vector to hold Unit instances

    # List all files in the folder, sorted by the number at the start of the file name.
    # This order is the unit index `u` in the models. Files without a number come last.
    files = readdir(folder_path; join=true)
    sort!(files, by = f -> begin
    name = basename(f)
    m = match(r"^\d+", name)
    m === nothing ? typemax(Int) : parse(Int, m.match)
    end)
    # Iterate through each file
    for file in files
        if endswith(file, ".json")  # Ensure the file is a JSON file
            #print(file)
            # Read and parse the JSON file
            json_data = JSON3.read(file, Dict{String, Any})
            #json_data = convert_symbols_to_strings(Dict(json_data))
            #print(typeof(json_data))
            unit = parse_multi_unit(json_data, carrier_matrix)  # Parse into a Unit instance
            push!(units, unit)  # Add the unit to the vector
        end
    end

    return units  # Return the vector of units
end


# -----------------------------------------------------------------------------
# Load the multi-state units
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
multi_units_folder = joinpath(process_data_dir, "multi_units")  # Path to the multi_units folder
multi_units = load_multi_units_from_folder(multi_units_folder, carrier_matrix)




# The models use one index set 1:Q for the states of all multi-state units, where Q
# is the largest number of states of any unit. Units with fewer states are padded
# with copies of their off-state, which does not change their behaviour.
if !isempty(multi_units)
    state_vec = getfield.(multi_units, :states)
    Q    = maximum(length.(state_vec))

    for u in 1:length(multi_units)
        states = multi_units[u].states
        a_input = multi_units[u].a_input
        a_output = multi_units[u].a_output
        b_input = multi_units[u].b_input
        b_output = multi_units[u].b_output
        min_input = multi_units[u].min_input
        max_input = multi_units[u].max_input
        min_output = multi_units[u].min_output
        max_output = multi_units[u].max_output
        if length(multi_units[u].states) < Q
            q_off = findfirst(==("off"), multi_units[u].states)
            while(length(states) < Q)
                states = push!(states,states[q_off])
                a_input = vcat(a_input, a_input[q_off,:]')
                a_output = vcat(a_output, a_output[q_off,:]')
                b_input = vcat(b_input, b_input[q_off,:]')
                b_output = vcat(b_output, b_output[q_off,:]')
                min_input = vcat(min_input, min_input[q_off,:]')
                max_input = vcat(max_input, max_input[q_off,:]')
                min_output = vcat(min_output, min_output[q_off,:]')
                max_output = vcat(max_output, max_output[q_off,:]')
                println("Multi_units $(multi_units[u].name): added off state to states")

            end
            multi_units[u].states = states
            multi_units[u].a_input = a_input
            multi_units[u].a_output = a_output
            multi_units[u].b_input = b_input
            multi_units[u].b_output = b_output
            multi_units[u].min_input = min_input
            multi_units[u].max_input = max_input
            multi_units[u].min_output = min_output
            multi_units[u].max_output = max_output
            multi_units[u].num_states = length(states)
        end 
    end
end


println("$(length(multi_units)) Multi Units are loaded")