# =============================================================================
# demand_prep.jl
#
# Reads the demands from the JSON files in process_data/demands.
#
# Requires line_prep.jl and the globals `Scenarios` (number of scenarios) and
# `T_considered` (number of time steps).
# Defines `demands` (all demands), `demands_nf` (the non-flexible demands) and
# `demands_transferable` (the demands that can be shifted in time).
#
# JSON fields of a demand (one file per demand)
#   required: "module" (= "demand"), "name", "node", "carrier", "demand", "price"
#   optional: "fulfill_exactly" (default true), "flexibility" (default
#             "non_flexible", alternative "transferable"), and for transferable
#             demands "flex_factor" (default 0) and "flex_interval" (default 6)
# "demand", "price" and "flex_factor" are either a number (constant over time and
# scenarios) or the name of a CSV file in time_series_data with one row per time
# step, no header, and either one column (used for all scenarios) or one column per
# scenario.
# =============================================================================

mutable struct Demand
    name::String              # Demand name
    node::Int64               # Demand node
    carrier::String           # demand carrier
    demand::Matrix{Float64}   # demand time series [time, scenario]
    price::Matrix{Float64}    # revenue per unit delivered [time, scenario]
    fulfill_exactly::Bool     # true: delivery must equal the demand; false: delivery may exceed it
    flexibility::Any          # Dict with "type" ("non_flexible" or "transferable") and, for
                              # transferable demands, "flex_factor" and "flex_interval"
end


"""
    parse_demand(json_dict, S, T_considered)

Check that `json_dict` (the content of one JSON file) describes a demand, fill in
the default values of the optional fields and return the `Demand`. `S` is the
number of scenarios and `T_considered` the number of time steps.
"""
function parse_demand(json_dict::Dict{String, Any}, S, T_considered)
    # Check for required fields
    required_fields = ["module", "name", "node", "carrier", "demand", "price"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "demand"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'demand'."))
    end
    # Extract required and optional fields
    name = json_dict["name"]
    node = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    carrier = json_dict["carrier"]
    

    fulfill_exactly = get(json_dict, "fulfill_exactly", true)
    demand_data = zeros(T_considered,S)



    # Demand as a [time, scenario] matrix. A number is used for all time steps and scenarios.
    if json_dict["demand"] isa Number
        for s in 1:S
            for t in 1:T_considered
                demand_data[t,s] = json_dict["demand"]
            end
        end
    else
        # File name: read the time series from the CSV file in time_series_data
        script_dir = @__DIR__  # Directory of this script
        time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
        demand_path = joinpath(time_data_dir, json_dict["demand"])  # Path to the CSV file 
        df = CSV.read(demand_path, DataFrame; header=false)
        if ncol(df)==1
            for s in 1:S
                demand_data[:,s] = Matrix(df)[1:T_considered,1]
            end
        else
            check_scenario_columns(df, S, name, "demand")  # Defined in line_prep.jl
            demand_data = Matrix(df)[1:T_considered,:]
        end
    end


    demand = demand_data


    # Price as a [time, scenario] matrix, in the same way
    price_data = zeros(T_considered,S)

    if json_dict["price"] isa Number
        for s in 1:S
            for t in 1:T_considered
                price_data[t,s] = json_dict["price"]
            end
        end
    else
        # File name: read the time series from the CSV file in time_series_data
        script_dir = @__DIR__  # Directory of this script
        time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
        price_path = joinpath(time_data_dir, json_dict["price"])  # Path to the CSV file 
        df = CSV.read(price_path, DataFrame; header=false)
        # Convert the DataFrame to a matrix
        if ncol(df)==1
            for s in 1:S
                price_data[:,s] = Matrix(df)[1:T_considered,1]
            end
        else
            check_scenario_columns(df, S, name, "price")
            price_data = Matrix(df)[1:T_considered,:]
        end
    end

    price = price_data

    # Flexibility. A transferable demand can be shifted in time: in each time step at
    # most flex_factor * demand can be shifted up or down, and within every window of
    # flex_interval time steps the upward and downward shifts must cancel out.
    flex_type = get(json_dict, "flexibility", "non_flexible")
    flexibility = Dict(
        "type" => "non_flexible"
    )
    if flex_type=="transferable"
        flex_factor =   get(json_dict, "flex_factor", 0)
        flex_interval = get(json_dict, "flex_interval", 6)
        flex_factor_ts = zeros(T_considered,S)
        if flex_factor isa Number
            for s in 1:S
                for t in 1:T_considered
                    flex_factor_ts[t,s] = flex_factor
                end
            end
        else
            # File name: read the time series from the CSV file in time_series_data
            script_dir = @__DIR__  # Directory of this script
            time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
            flex_factor_path = joinpath(time_data_dir, json_dict["flex_factor"])  # Path to the CSV file 
            df = CSV.read(flex_factor_path, DataFrame; header=false)
            # Convert the DataFrame to a matrix
            if ncol(df)==1
                for s in 1:S
                    flex_factor_ts[:,s] = Matrix(df)[1:T_considered,1]
                end
            else
                check_scenario_columns(df, S, name, "flex_factor")
                flex_factor_ts = Matrix(df)[1:T_considered,:]
            end
        end
        flexibility = Dict(
            "type" => flex_type,
            "flex_interval" => flex_interval,
            "flex_factor" => flex_factor_ts
        )
    end
    # Create and return the Unit instance
    return Demand(name, node, carrier, demand, price, fulfill_exactly, flexibility)
end


"""
    load_demands_from_folder(folder_path, S, T_considered)

Read all JSON files in `folder_path` and return them as a vector of `Demand`s.
"""
function load_demands_from_folder(folder_path::String, S, T_considered)
    demands = Vector{Demand}()  # Initialize an empty vector to hold Unit instances

    # List all files in the folder, sorted by the number at the start of the file name.
    # This order is the demand index `d` in the models. Files without a number come last.
    files = readdir(folder_path; join=true)
    sort!(files, by = f -> begin
    name = basename(f)
    m = match(r"^\d+", name)
    m === nothing ? typemax(Int) : parse(Int, m.match)
    end)

    # Iterate through each file
    for file in files
        if endswith(file, ".json")  # Ensure the file is a JSON file
        
            # Read and parse the JSON file
            json_data = JSON3.read(file)

            json_data = convert_symbols_to_strings(Dict(json_data))
            demand_file = parse_demand(json_data, S, T_considered)  # Parse into a Unit instance
            push!(demands, demand_file)  # Add the unit to the vector
        end
    end

    return demands  # Return the vector of units
end




# -----------------------------------------------------------------------------
# Load the demands
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
demands_folder = joinpath(process_data_dir, "demands")  # Path to the demands folder
demands = load_demands_from_folder(demands_folder, Scenarios, T_considered)


# Split the demands by flexibility type; the models treat the two groups differently
demands_nf = [d for d in demands if d.flexibility["type"] == "non_flexible"]
demands_transferable = [d for d in demands if d.flexibility["type"] == "transferable"]

println("$(length(demands)) Demands are loaded")

