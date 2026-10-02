# =============================================================================
# transport_unit_prep.jl
#
# Reads the transport units from the JSON files in process_data/transport_units.
# A transport unit is a fleet of vehicles that ships one carrier in discrete
# trips. Its routes are not defined here: every line that starts at the node of
# the transport unit is a route of that unit (see "distance" and "tau_transport"
# in line_prep.jl).
#
# Requires line_prep.jl (`carrier_matrix`).
#
# JSON fields of a transport unit (one file per unit), all required:
#   "module" (= "transport_unit"), "name", "node", "carrier", "cost_fixed",
#   "cost_distance", "cost_time", "min_output", "max_output", "fleet_cap"
# The cost of one trip is
#   cost_fixed + cost_distance * (distance of the route) + cost_time * (tau_transport of the route)
# =============================================================================

struct Transport_Unit
    name::String                    # Unit Name
    node::Int64                     # Unit node
    carrier::String                 # Energy Carrier
    cost_fixed::Float64             # Fixed cost per dispatch
    cost_distance::Float64          # Cost per unit of route distance
    cost_time::Float64              # Cost per unit of travel time
    min_output::Float64             # Minimum load of one trip
    max_output::Float64             # Maximum load of one trip
    fleet_cap::Int64                # Fleet capacity: number of vehicles that can be under way at the same time
end

"""
    parse_transport_unit(json_dict, carrier_matrix)

Check that `json_dict` (the content of one JSON file) describes a transport unit
and return the `Transport_Unit`.
"""
function parse_transport_unit(json_dict::Dict{String, Any}, carrier_matrix::Matrix{String})
    # Check for required fields
    required_fields = ["module", "name", "carrier", "node", "cost_fixed", "cost_distance", "cost_time", "min_output", "max_output", "fleet_cap"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "transport_unit"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'transport_unit'."))
    end
    #println("carrier check")
    #print(carrier_matrix)
    # Extract required and optional fields
    name           = json_dict["name"]
    node           = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    carrier        = json_dict["carrier"]
    cost_fixed     = json_dict["cost_fixed"]
    cost_distance  = json_dict["cost_distance"]
    cost_time      = json_dict["cost_time"]
    min_output     = json_dict["min_output"]
    max_output     = json_dict["max_output"]
    fleet_cap      = json_dict["fleet_cap"]


    # Create and return the Unit instance
    return Transport_Unit(name, node, carrier, cost_fixed, cost_distance, cost_time, min_output, max_output, fleet_cap)
end


"""
    load_transport_units_from_folder(folder_path, carrier_matrix)

Read all JSON files in `folder_path` and return them as a vector of `Transport_Unit`s.
"""
function load_transport_units_from_folder(folder_path::String, carrier_matrix::Matrix{String})
    transport_units = Vector{Transport_Unit}()  # Initialize an empty vector to hold Unit instances

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
            transport_unit = parse_transport_unit(json_data, carrier_matrix)  # Parse into a Unit instance
            push!(transport_units, transport_unit)  # Add the unit to the vector
        end
    end

    return transport_units  # Return the vector of units
end


# -----------------------------------------------------------------------------
# Load the transport units
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
transport_units_folder = joinpath(process_data_dir, "transport_units")  # Path to the transport_units folder
transport_units = load_transport_units_from_folder(transport_units_folder, carrier_matrix)






println("$(length(transport_units)) Transport Units are loaded")




