# =============================================================================
# cg_unit_prep.jl
#
# Reads the cogeneration (CG) units from the JSON files in process_data/cg_units.
# The feasible operating region of a CG unit is the convex hull of a set of
# extreme points. Each extreme point gives the output of every carrier ("extreme")
# and the corresponding input of every carrier ("fuel").
#
# Requires line_prep.jl (`carriers`, `carrier_matrix`) and the global `M_unit`
# (large number, used as "no limit" for the ramp rates).
# Defines `cg_units` and, if there are CG units, `extreme_cgs` and `G`.
#
# JSON fields of a CG unit (one file per unit)
#   required: "module" (= "cg_unit"), "name", "node", "cost_operating",
#             "extreme", "fuel"
#   optional: "start_stop_cost" (default 0), "min_down_time" (0), "min_up_time" (0),
#             "start_up_time" (0), "ramp_up" (M_unit), "ramp_down" (M_unit)
# "extreme" and "fuel" are objects with, per carrier, a vector with one value per
# extreme point, e.g. {"electricity": [0, 10, 8], "heat": [0, 0, 12]}. Both must
# have the same number of extreme points. "cost_operating", "ramp_up" and
# "ramp_down" are objects with one value per carrier.
# =============================================================================

mutable struct CG_Unit
    name::String                    # Unit Name
    node::Int64                     # Unit node
    start_stop_cost::Float64        # Cost of starting and stopping / time
    min_down_time::Int64            # Minimum down time 
    min_up_time::Int64              # Minimum up time
    start_up_time::Int64            # Start up time
    cost_operating::Vector{Float64} # Per unit operating cost
    extreme::Matrix{Float64}        # Output of each carrier in each extreme point [carrier, extreme point]
    fuel::Matrix{Float64}           # Input of each carrier in each extreme point [carrier, extreme point]
    ramp_up::Vector{Float64}        # Ramp up for each energy carrier
    ramp_down::Vector{Float64}      # Ramp down for each energy carrier
end

"""
    parse_cg_unit(json_dict, carrier_matrix, file)

Check that `json_dict` (the content of the JSON file `file`) describes a CG unit,
fill in the default values of the optional fields and return the `CG_Unit`.
"""
function parse_cg_unit(json_dict::Dict{String, Any}, carrier_matrix::Matrix{String}, file)
    # Check for required fields
    required_fields = ["module", "name", "node", "cost_operating", "fuel", "extreme"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing Cogeneration required field: $field in file $file"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "cg_unit"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'cg_unit'."))
    end
    #print(json_dict["fuel"])
    #println("carrier check")
    #print(carrier_matrix)
    # Extract required and optional fields
    name = json_dict["name"]
    node = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    #fuel = json_dict["fuel"]

    N_carriers      = size(carrier_matrix, 1)  # Use the size of the carrier_matrix
    start_stop_cost = get(json_dict, "start_stop_cost", 0.0)
    min_down_time   = get(json_dict, "min_down_time", 0)
    min_up_time     = get(json_dict, "min_up_time", 0)
    start_up_time   = get(json_dict, "start_up_time", 0)

    # Number of extreme points: the length of the longest vector in "extreme"
    max_extreme = 0
    for c in 1:size(carriers,1)
        if haskey(json_dict["extreme"], carriers[c])
            if length(json_dict["extreme"][carriers[c]]) > max_extreme
                max_extreme = size(json_dict["extreme"][carriers[c]],1)
            end
        end
    end

    # extreme_matrix[c,x]: output of carrier c in extreme point x (0 for carriers not listed)
    extreme_matrix = zeros(Float64, N_carriers, max_extreme)

    for c in 1:length(carriers)
        for x in 1:max_extreme
            if haskey(json_dict["extreme"], carriers[c])
                extreme_matrix[c,x] = json_dict["extreme"][carriers[c]][x]
            end
        end
    end

    # The same for the inputs: number of extreme points in "fuel"
    max_fuel = 0
    for c in 1:size(carriers,1)
        if haskey(json_dict["fuel"], carriers[c])
            if length(json_dict["fuel"][carriers[c]]) > max_fuel
                max_fuel = size(json_dict["fuel"][carriers[c]],1)
            end
        end
    end

    # fuel_matrix[c,x]: input of carrier c in extreme point x (0 for carriers not listed)
    fuel_matrix = zeros(Float64, N_carriers, max_extreme)

    for c in 1:length(carriers)
        for x in 1:max_fuel
            if haskey(json_dict["fuel"], carriers[c])
                fuel_matrix[c,x] = json_dict["fuel"][carriers[c]][x]
            end
        end
    end

    if size(extreme_matrix)[2] != size(fuel_matrix)[2]
        throw(DimensionMismatch("Cogeneration Extreme Matrix dimensions must match, got $(size(extreme_matrix)[2]) number of production extreme points vs $(size(fuel_matrix)[2]) number of fuel extreme points. Align these and run again"))
    end
    # Convert the carrier-dependent fields to vectors in the order of `carriers`.
    # Default: 0, and M_unit (no limit) for the ramp rates.
    cost_operating = zeros(size(carriers,1))
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
    end

    # Create and return the Unit instance
    return CG_Unit(name, node, start_stop_cost, min_down_time, min_up_time, start_up_time, cost_operating, extreme_matrix, fuel_matrix, ramp_up, ramp_down)
end


"""
    load_cg_units_from_folder(folder_path, carrier_matrix)

Read all JSON files in `folder_path` and return them as a vector of `CG_Unit`s.
"""
function load_cg_units_from_folder(folder_path::String, carrier_matrix::Matrix{String})
    cg_units = Vector{CG_Unit}()  # Initialize an empty vector to hold Unit instances

    # List all files in the folder, sorted by the number at the start of the file name.
    # This order is the unit index `u` in the models. Files without a number come last.
    files = readdir(folder_path; join=true)
    sort!(files, by = f -> begin
    name = basename(f)
    m = match(r"^\d+", name)
    m === nothing ? typemax(Int) : parse(Int, m.match)
    end)
    #print(files)
    # Iterate through each file
    for file in files
        if endswith(file, ".json")  # Ensure the file is a JSON file
            #print(file)
            # Read and parse the JSON file
            json_data = JSON3.read(file, Dict{String, Any})
            #json_data = convert_symbols_to_strings(Dict(json_data))
            #print(typeof(json_data))
            cg_unit = parse_cg_unit(json_data, carrier_matrix, file)  # Parse into a Unit instance
            push!(cg_units, cg_unit)  # Add the unit to the vector
        end
    end

    return cg_units  # Return the vector of units
end


# -----------------------------------------------------------------------------
# Load the CG units
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
cg_units_folder = joinpath(process_data_dir, "cg_units")  # Path to the cg_units folder
cg_units = load_cg_units_from_folder(cg_units_folder, carrier_matrix)

# The models use one index set 1:G for the extreme points of all CG units, where G
# is the largest number of extreme points of any unit. Units with fewer extreme
# points are padded by repeating their first extreme point, which does not change
# their feasible operating region.
if !isempty(cg_units)
    extreme_cgs = getfield.(cg_units, :extreme)
    G    = maximum(size.(extreme_cgs, 2))

    for g in 1:length(cg_units)
        extreme_mat = cg_units[g].extreme
        fuel_mat = cg_units[g].fuel
        if size(extreme_mat, 2) < G
            while(size(extreme_mat, 2) < G)
                extreme_mat = hcat(extreme_mat, extreme_mat[:,1])
                fuel_mat = hcat(fuel_mat, fuel_mat[:,1])
                println("CG_unit $(cg_units[g].name): added column to extreme")

            end
            #cg_units[g] = CG_Unit(cg_units[g].name, cg_units[g].node, cg_units[g].start_stop_cost,cg_units[g]. min_down_time, cg_units[g].min_up_time, cg_units[g].start_up_time, cg_units[g].cost_operating, extreme_mat, cg_units[g].fuel_lin_reg, cg_units[g].fuel_constant, cg_units[g].ramp_up, cg_units[g].ramp_down)
            cg_units[g].extreme = extreme_mat
            cg_units[g].fuel = fuel_mat
        end 
    end
end

println("$(length(cg_units)) Cogeneration Units are loaded")