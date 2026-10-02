# =============================================================================
# source_prep.jl
#
# Reads the sources from the JSON files in process_data/sources. A source supplies
# one carrier to the network, e.g. a PV park, a wind turbine or a grid connection.
#
# Requires line_prep.jl and the globals `Scenarios` (number of scenarios),
# `T_considered` (number of time steps) and `M_sources` (large number, used as
# "unlimited" availability).
#
# JSON fields of a source (one file per source), all required:
#   "module" (= "source"), "name", "node", "carrier", "output", "price", "here_and_now"
# "output" is the amount that is available per time step and "price" the price per
# unit taken from the source. Both are either a number (constant over time and
# scenarios) or the name of a CSV file without header in time_series_data, with
# one row per time step and either one column (used for all scenarios) or one
# column per scenario. "output" can also be "M" for an unlimited source.
# =============================================================================

mutable struct Source
    name::String              # Source name
    node::Int64               # Source node
    carrier::String           # output carrier
    output::Matrix{Float64}   # available output [time, scenario]
    price::Matrix{Float64}    # price per unit taken from the source [time, scenario]
    here_and_now::Bool        # true: the amount taken in the here-and-now time steps
                              # must be the same in all scenarios
end

"""
    parse_sources(json_dict, S, T_considered)

Check that `json_dict` (the content of one JSON file) describes a source and return
the `Source`. `S` is the number of scenarios and `T_considered` the number of time steps.
"""
function parse_sources(json_dict::Dict{String, Any}, S, T_considered)
    # Check for required fields
    required_fields = ["module", "name", "node", "carrier", "output", "price","here_and_now"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "source"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'source'."))
    end
    # Extract required and optional fields
    name         = json_dict["name"]
    node         = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    carrier      = json_dict["carrier"]
    here_and_now = json_dict["here_and_now"]

    output_data = zeros(T_considered,S)


    # Available output as a [time, scenario] matrix: a number (used for all time steps
    # and scenarios), "M" (unlimited) or the name of a CSV file
    if json_dict["output"] isa Number
        for s in 1:S
            for t in 1:T_considered
                output_data[t,s] = json_dict["output"]
            end
        end
    elseif json_dict["output"] == "M"
        for s in 1:S
            for t in 1:T_considered
                output_data[t,s] = M_sources
            end
        end
    else
        # File name: read the time series from the CSV file in time_series_data
        script_dir = @__DIR__  # Directory of this script
        time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
        output_path = joinpath(time_data_dir, json_dict["output"])  # Path to the CSV file 
        df = CSV.read(output_path, DataFrame; header=false)
        # Convert the DataFrame to a matrix
        if ncol(df)==1
            for s in 1:S
                output_data[:,s] = Matrix(df)[1:T_considered,1]
            end
        else
            check_scenario_columns(df, S, name, "output")  # Defined in line_prep.jl
            output_data = Matrix(df)[1:T_considered,:]
        end
    end

    output = output_data

    # Price as a [time, scenario] matrix: a number or the name of a CSV file
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


    # Create and return the Unit instance
    return Source(name, node, carrier, output, price, here_and_now)
end

"""
    load_sources_from_folder(folder_path, S, T_considered)

Read all JSON files in `folder_path` and return them as a vector of `Source`s.
"""
function load_sources_from_folder(folder_path::String, S, T_considered)
    sources = Vector{Source}()  # Initialize an empty vector to hold Unit instances

    # List all files in the folder, sorted by the number at the start of the file name.
    # This order is the source index `e` in the models. Files without a number come last.
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
            source_file = parse_sources(json_data, S, T_considered)  # Parse into a Unit instance
            push!(sources, source_file)  # Add the unit to the vector
        end
    end

    return sources  # Return the vector of units
end




# -----------------------------------------------------------------------------
# Load the sources
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
sources_folder = joinpath(process_data_dir, "sources")  # Path to the sources folder
sources = load_sources_from_folder(sources_folder, Scenarios, T_considered)

println("$(length(sources)) Sources are loaded")