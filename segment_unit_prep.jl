# =============================================================================
# segment_unit_prep.jl
#
# Reads the segment units from the JSON files in process_data/segment_units.
# A segment unit is a conversion unit whose conversion factors and capacities
# depend on the level of a storage: the range of that storage level is divided
# into segments, and each segment has its own conversion factors and bounds.
#
# Requires line_prep.jl (`carriers`, `carrier_matrix`) and the global `M_unit`
# (large number, used as "no limit" for the ramp rates).
# Defines `segment_units` and, if there are segment units, `I`.
#
# JSON fields of a segment unit (one file per unit)
#   required: "module" (= "segment_unit"), "name", "node", "cost_operating",
#             "min_input", "max_input", "min_output", "max_output",
#             "num_segments", "min_state", "max_state", "segment_determiner"
#   optional: "start_stop_cost" (default 0), "min_down_time" (0), "min_up_time" (0),
#             "start_up_time" (0), "ramp_up" (M_unit), "ramp_down" (M_unit)
# "min_input", "max_input", "min_output" and "max_output" are objects with, per
# carrier, a vector with one value per segment. "min_state" and "max_state" are
# vectors with the lower and upper storage level of each segment, and
# "segment_determiner" is the index of the storage whose level selects the segment.
# "cost_operating", "ramp_up" and "ramp_down" are objects with one value per carrier.
# =============================================================================
#using JSON
mutable struct Segment_Unit
    name::String                    # Unit Name
    node::Int64                     # Unit node
    start_stop_cost::Float64        # Cost of starting and stopping / time
    min_down_time::Int64            # Minimum down time 
    min_up_time::Int64              # Minimum up time
    start_up_time::Int64            # Start up time
    cost_operating::Vector{Float64} # Per unit operating cost
    conv_matrix::Array{Float64, 3}    # Conversion factors [segment, input carrier, output carrier]
    min_input::Matrix{Float64}      # Minimum input vector
    max_input::Matrix{Float64}      # Maximum input vector
    min_output::Matrix{Float64}     # Minimum output vector
    max_output::Matrix{Float64}     # Maximum output vector,
    ramp_up::Vector{Float64}        # Ramp up for each energy carrier
    ramp_down::Vector{Float64}      # Ramp down for each energy carrier
    min_ramp::Vector{Float64}       # Minimum ramp down for each carrier accross all segments, used in ramp constraints
    min_state::Vector{Float64}      # Lower bound of the storage level of each segment
    max_state::Vector{Float64}      # Upper bound of the storage level of each segment
    num_segments::Int64             # Number of segments
    segment_determiner::Int64       # The storage whose content determine the state segment
end


"""
    parse_segment_unit(json_dict, carrier_matrix)

Check that `json_dict` (the content of one JSON file) describes a segment unit,
fill in the default values of the optional fields and return the `Segment_Unit`.
"""
function parse_segment_unit(json_dict::Dict{String, Any}, carrier_matrix::Matrix{String})
    # Check for required fields
    required_fields = ["module", "name", "node", "cost_operating", "min_input", "max_input", "min_output", "max_output", "num_segments", "min_state", "max_state","segment_determiner"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "segment_unit"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'segment_unit'."))
    end
    # Extract required and optional fields
    name = json_dict["name"]
    node = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    num_segments = json_dict["num_segments"]
    segment_determiner = json_dict["segment_determiner"]
    check_node(segment_determiner, name, "segment_determiner")  # The storage index must be a whole number

    N_carriers      = size(carrier_matrix, 1)  # Use the size of the carrier_matrix
    start_stop_cost = get(json_dict, "start_stop_cost", 0.0)
    min_down_time   = get(json_dict, "min_down_time", 0)
    min_up_time     = get(json_dict, "min_up_time", 0)
    start_up_time   = get(json_dict, "start_up_time", 0)

    # Conversion matrix: conv_matrix[s,i,j] is the amount of carrier j that is produced
    # per unit of carrier i that is consumed in segment s. The factors are not given in
    # the JSON file but derived from the capacities of the segment:
    # max_output[j][s] / max_input[i][s]. Other elements keep the value 0.
    conv_matrix = zeros(Float64, num_segments, N_carriers, N_carriers)

    # The names in carrier_matrix ("input_output") identify the carrier pair of each element
    for i in 1:size(carrier_matrix, 1)
        for j in 1:size(carrier_matrix, 2)
            element_name = carrier_matrix[i, j]
            # Split the combined string to identify the inputs and outputs
            split_name = split(element_name, "_")
            #print(split_name)
            
            if length(split_name) == 2  # Valid "input_output" pair
                input_name, output_name = split_name[1], split_name[2]
                
                # Check if input and output exist in max_input and max_output
                if haskey(json_dict["max_input"], input_name) && haskey(json_dict["max_output"], output_name)
                    for s in 1:num_segments
                        if json_dict["max_output"][output_name][s]!=0 && json_dict["max_input"][input_name][s]!=0
                        #print(json_dict["max_output"][output_name][s] / json_dict["max_input"][input_name][s])
                            conv_matrix[s,i,j] =  json_dict["max_output"][output_name][s] / json_dict["max_input"][input_name][s]
                        end
                    end
                end
            else
                # Diagonal element: the same carrier is input and output
                input_name, output_name = split_name[1], split_name[1]
                #print(output_name)
                # Check if input and output exist in max_input and max_output
                if haskey(json_dict["max_input"], input_name) && haskey(json_dict["max_output"], output_name)
                    for s in 1:num_segments
                        if json_dict["max_output"][output_name][s]!=0 && json_dict["max_input"][input_name][s]!=0
                        #print(json_dict["max_output"][output_name][s] / json_dict["max_input"][input_name][s])
                            conv_matrix[s,i,j] =  json_dict["max_output"][output_name][s] / json_dict["max_input"][input_name][s]
                        end
                    end
                end
            end
        end
    end
    # Convert the carrier-dependent fields to vectors in the order of `carriers`, and
    # the segment-dependent bounds to [segment, carrier] matrices. Default: 0, and
    # M_unit (no limit) for the ramp rates.
    cost_operating = zeros(size(carriers,1))
    min_input      = zeros(num_segments, size(carriers,1))
    max_input      = zeros(num_segments, size(carriers,1))
    min_output     = zeros(num_segments, size(carriers,1))
    max_output     = zeros(num_segments, size(carriers,1))
    min_output     = zeros(num_segments, size(carriers,1))
    max_output     = zeros(num_segments, size(carriers,1))
    ramp_up        = fill(M_unit, length(carriers))
    ramp_down      = fill(M_unit, length(carriers))

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

        for s in 1:num_segments
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

    # Smallest minimum output of each carrier over all segments
    min_ramp = vec(minimum(min_output, dims = 1))

    min_state      = Float64.(json_dict["min_state"])
    max_state      = Float64.(json_dict["max_state"])

    # Create and return the Unit instance
    return Segment_Unit(name, node, start_stop_cost, min_down_time, min_up_time, start_up_time, cost_operating, conv_matrix, min_input, max_input, min_output, max_output, ramp_up, ramp_down,min_ramp, min_state, max_state,num_segments,segment_determiner)
end


"""
    load_segment_units_from_folder(folder_path, carrier_matrix)

Read all JSON files in `folder_path` and return them as a vector of `Segment_Unit`s.
"""
function load_segment_units_from_folder(folder_path::String, carrier_matrix::Matrix{String})
    segment_units = Vector{Segment_Unit}()  # Initialize an empty vector to hold multi efficiency unit instances

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
            #print(typeof(json_data))
            segment_unit = parse_segment_unit(json_data, carrier_matrix)  # Parse into a Unit instance
            push!(segment_units, segment_unit)  # Add the unit to the vector
        end
    end

    return segment_units  # Return the vector of units
end


# -----------------------------------------------------------------------------
# Load the segment units
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
segment_units_folder = joinpath(process_data_dir, "segment_units")  # Path to the segment_units folder
segment_units = load_segment_units_from_folder(segment_units_folder, carrier_matrix)


# The models use one index set 1:I for the segments of all segment units, where I is
# the largest number of segments of any unit. Units with fewer segments are padded
# with copies of their first segment.
if !isempty(segment_units)
    I =maximum(getfield.(segment_units, :num_segments))


    for u in 1:length(segment_units)
        conv_matrix = segment_units[u].conv_matrix
        min_input = segment_units[u].min_input
        max_input = segment_units[u].max_input
        min_output = segment_units[u].min_output
        max_output = segment_units[u].max_output
        min_state = segment_units[u].min_state
        max_state = segment_units[u].max_state
        num_segments = segment_units[u].num_segments



        if segment_units[u].num_segments < I
            while(length(max_state) < I)
                conv_matrix = vcat(conv_matrix, conv_matrix[1:1,:,:])
                min_input  = vcat(min_input,  min_input[1:1,:])
                max_input  = vcat(max_input,  max_input[1:1,:])
                min_output = vcat(min_output, min_output[1:1,:])
                max_output = vcat(max_output, max_output[1:1,:])
                min_state  = vcat(min_state,  min_state[1:1])
                max_state  = vcat(max_state,  max_state[1:1])
                num_segments = num_segments + 1
                println("Multi_effiency_units $(segment_units[u].name): added first segments to segments")

            end
            segment_units[u].conv_matrix  = conv_matrix
            segment_units[u].min_input    = min_input
            segment_units[u].max_input    = max_input
            segment_units[u].min_output   = min_output
            segment_units[u].max_output   = max_output
            segment_units[u].min_state    = min_state
            segment_units[u].max_state    = max_state
            segment_units[u].num_segments = num_segments
        end 
    end
end



println("$(length(segment_units)) Multi Efficiency Units are loaded")




