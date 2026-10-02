# =============================================================================
# unit_prep.jl
#
# Reads the standard conversion units from the JSON files in process_data/units.
# A standard unit converts its input carriers into its output carriers with fixed
# conversion factors and can be switched on and off.
#
# Requires line_prep.jl (`carriers`, `carrier_matrix`) and the global `M_unit`
# (large number, used as "no limit" for the ramp rates).
#
# JSON fields of a unit (one file per unit)
#   required: "module" (= "unit"), "name", "node", "cost_operating", "min_input",
#             "max_input", "min_output", "max_output"
#   optional: "start_stop_cost" (default 0), "min_down_time" (0), "min_up_time" (0),
#             "start_up_time" (0), "ramp_up" (M_unit), "ramp_down" (M_unit)
# The fields "cost_operating", "min_input", "max_input", "min_output", "max_output",
# "ramp_up" and "ramp_down" are objects with one value per carrier, e.g.
# {"electricity": 10.0}. Carriers that are left out get the value 0 (M_unit for
# the ramp rates).
# =============================================================================
using JSON3
struct Unit
    name::String                    # Unit Name
    node::Int64                     # Unit node
    start_stop_cost::Float64        # Cost of starting and stopping / time
    min_down_time::Int64            # Minimum down time 
    min_up_time::Int64              # Minimum up time
    start_up_time::Int64            # Start up time
    cost_operating::Vector{Float64} # Per unit operating cost
    conv_matrix::Matrix{Float64}    # Converison NxN matrix of Float64
    min_input::Vector{Float64}      # Minimum input vector
    max_input::Vector{Float64}      # Maximum input vector
    min_output::Vector{Float64}     # Minimum output vector
    max_output::Vector{Float64}     # Maximum output vector,
    ramp_up::Vector{Float64}        # Ramp up for each energy carrier
    ramp_down::Vector{Float64}      # Ramp down for each energy carrier
end

"""
    parse_unit(json_dict, carrier_matrix)

Check that `json_dict` (the content of one JSON file) describes a unit, fill in the
default values of the optional fields and return the `Unit`. All carrier-dependent
fields are converted to vectors in the order of `carriers`.
"""
function parse_unit(json_dict::Dict{String, Any}, carrier_matrix::Matrix{String})
    # Check for required fields
    required_fields = ["module", "name", "node", "cost_operating", "min_input", "max_input", "min_output", "max_output"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "unit"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'unit'."))
    end
    #println("carrier check")
    #print(carrier_matrix)
    # Extract required and optional fields
    name = json_dict["name"]
    node = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)

    N_carriers      = size(carrier_matrix, 1)  # Use the size of the carrier_matrix
    start_stop_cost = get(json_dict, "start_stop_cost", 0.0)
    min_down_time   = get(json_dict, "min_down_time", 0)
    min_up_time     = get(json_dict, "min_up_time", 0)
    start_up_time   = get(json_dict, "start_up_time", 0)

    # Conversion matrix: conv_matrix[i,j] is the amount of carrier j that is produced
    # per unit of carrier i that is consumed. The factors are not given in the JSON
    # file but derived from the capacities: max_output[j] / max_input[i]. Pairs of
    # which the input or the output is not used by the unit keep the value 0.
    conv_matrix = zeros(Float64, N_carriers, N_carriers)

    # The names in carrier_matrix ("input_output") identify the carrier pair of each element
    for i in 1:size(carrier_matrix, 1)
        for j in 1:size(carrier_matrix, 2)
            element_name = carrier_matrix[i, j]
            # Split the combined string to identify the inputs and outputs
            split_name = split(element_name, "_")
            
            if length(split_name) == 2  # Valid "input_output" pair
                input_name, output_name = split_name[1], split_name[2]
                
                # Check if input and output exist in max_input and max_output
                if haskey(json_dict["max_input"], input_name) && haskey(json_dict["max_output"], output_name)
                    conv_matrix[i, j] =  json_dict["max_output"][output_name] / json_dict["max_input"][input_name]
                end
            else
                # Diagonal element: the same carrier is input and output
                input_name, output_name = split_name[1], split_name[1]
                if haskey(json_dict["max_input"], input_name) && haskey(json_dict["max_output"], output_name) && json_dict["max_output"][output_name]!=0 && json_dict["max_input"][input_name] != 0
                    conv_matrix[i, j] =  json_dict["max_output"][output_name] / json_dict["max_input"][input_name]
                end
            end
        end
    end
    # Convert the carrier-dependent fields to vectors in the order of `carriers`.
    # Default: 0, and M_unit (no limit) for the ramp rates.
    cost_operating = zeros(size(carriers,1))
    min_input      = zeros(size(carriers,1))
    max_input      = zeros(size(carriers,1))
    min_output     = zeros(size(carriers,1))
    max_output     = zeros(size(carriers,1))
    ramp_up        = fill(M_unit, length(carriers))
    ramp_down      = fill(M_unit, length(carriers))

    for c in 1:size(carriers,1)
        if haskey(json_dict["cost_operating"], carriers[c])
            cost_operating[c] = json_dict["cost_operating"][carriers[c]]
        end
        if haskey(json_dict["min_input"], carriers[c])
            min_input[c] = json_dict["min_input"][carriers[c]]
        end
        if haskey(json_dict["max_input"], carriers[c])
            max_input[c] = json_dict["max_input"][carriers[c]]
        end
        if haskey(json_dict["min_output"], carriers[c])
            min_output[c] = json_dict["min_output"][carriers[c]]
        end
        if haskey(json_dict["max_output"], carriers[c])
            max_output[c] = json_dict["max_output"][carriers[c]]
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
    end

    # Create and return the Unit instance
    return Unit(name, node, start_stop_cost, min_down_time, min_up_time, start_up_time, cost_operating, conv_matrix, min_input, max_input, min_output, max_output, ramp_up, ramp_down)
end


"""
    load_units_from_folder(folder_path, carrier_matrix)

Read all JSON files in `folder_path` and return them as a vector of `Unit`s.
"""
function load_units_from_folder(folder_path::String, carrier_matrix::Matrix{String})
    units = Vector{Unit}()  # Initialize an empty vector to hold Unit instances

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
            unit = parse_unit(json_data, carrier_matrix)  # Parse into a Unit instance
            push!(units, unit)  # Add the unit to the vector
        end
    end

    return units  # Return the vector of units
end


# -----------------------------------------------------------------------------
# Load the units
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
units_folder = joinpath(process_data_dir, "units")  # Path to the units folder
units = load_units_from_folder(units_folder, carrier_matrix)

println("$(length(units)) Units are loaded")




