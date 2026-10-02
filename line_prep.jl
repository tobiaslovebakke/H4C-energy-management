# =============================================================================
# line_prep.jl
#
# Reads the lines (arcs) of the network from the JSON files in process_data/lines
# and derives the list of carriers and the line lags from them.
#
# This file must be included first: it loads the packages used by all prep files
# and defines `carriers`, `carrier_matrix`, `L` and `lags`, on which the other
# prep files and the optimisation models rely.
#
# JSON fields of a line (one file per line)
#   required: "module" (= "line"), "name", "from", "to", "carrier"
#   optional: "min_cap" (default 0), "max_cap" (default M_line), "lag" (default 0),
#             "tau_transport" (default 1), "temperature" (default 0),
#             "distance" (default 0), "cost" (default 0)
# =============================================================================

using JSON3
using Glob
using CSV
using DataFrames

# A line is a directed arc that transports one carrier between two nodes
mutable struct Line
    name::String            # Line name
    from::Int64             # Node where the line starts
    to::Int64               # Node where the line ends
    carrier::String         # Carrier transported over the line
    min_cap::Float64        # Minimum flow per time step
    max_cap::Float64        # Maximum flow per time step
    lag::Int64              # Number of time steps between sending and arrival
    tau_transport::Int64    # Number of time steps a vehicle is occupied (transport routes only)
    temperature::Float64    # Temperature of the carrier
    distance::Float64       # Length of the line (used for the transport cost)
    cost::Float64           # Cost per unit of flow sent over the line
end

# Default max_cap: a large value, i.e. effectively unlimited capacity
const M_line = 1.0e6

"""
    check_node(value, name, field)

Throw an error if `value` is not a whole number. `name` (the name of the line, unit,
storage, ...) and `field` (the JSON field) are only used in the error message.
Also used by the other prep files.
"""
function check_node(value, name, field)
    if !(value isa Real && !(value isa Bool) && isinteger(value))
        error("'$name': field \"$field\" must be a whole number, got $(repr(value))")
    end
end

"""
    check_scenario_columns(df, S, name, field)

Throw an error if the time-series table `df` (read from a CSV file) does not have
exactly one column per scenario, i.e. `S` columns. `name` (the name of the demand,
source, ...) and `field` (the JSON field) are only used in the error message.
Used by the demand, source and storage prep files.
"""
function check_scenario_columns(df, S, name, field)
    if ncol(df) != S
        error("'$name': the CSV file of field \"$field\" has $(ncol(df)) columns, but there are $S scenarios. It must have one column per scenario.")
    end
end

"""
    parse_line(data)

Check that `data` (the content of one JSON file) describes a line, fill in the
default values of the optional fields and return the `Line`.
"""
function parse_line(data::Dict{String, Any})
    # Check required fields
    required_fields = ["module", "name", "from", "to", "carrier"]
    
    for field in required_fields
        if !haskey(data, field)
            error("Missing required field: $field")
        end
    end

    # Check module
    if data["module"] != "line"
        error("JSON does not define a 'line' module")
    end

    # Check that the nodes are whole numbers (node numbers). 2 and 2.0 are accepted
    # (2.0 is converted to 2 when the Line is created), but not e.g. 2.1, "2" or true.
    for field in ["from", "to"]
        check_node(data[field], data["name"], field)
    end
    lag   = get(data, "lag", 0)
    tau_transport   = get(data, "tau_transport", 1)
    # Set default values for optional fields
    min_cap = haskey(data, "min_cap") ? data["min_cap"] : 0.0
    max_cap = haskey(data, "max_cap") ? data["max_cap"] : M_line
    temperature    = haskey(data, "temperature") ? data["temperature"] : 0
    distance       = get(data, "distance", 0.0)
    cost           = get(data, "cost", 0.0)   # Cost per unit of flow; 0 = free transport
    # Create and return the Line struct
    return Line(data["name"], data["from"], data["to"], data["carrier"], min_cap, max_cap, lag, tau_transport, temperature, distance, cost)
end


"""
    convert_symbols_to_strings(data)

JSON3 returns the keys of a JSON object as `Symbol`s. Convert the keys of the top
level of `data` to `String`s. Also used by the other prep files.
"""
function convert_symbols_to_strings(data::Dict{Symbol, Any})::Dict{String, Any}
    return Dict(string(k) => v for (k, v) in data)
end

"""
    load_lines_from_folder(folder_path)

Read all JSON files in `folder_path` and return them as a vector of `Line`s.
"""
function load_lines_from_folder(folder_path::String)::Vector{Line}
    files = glob("*.json", folder_path)
    # Sort the files by the number at the start of the file name ("1_...", "2_...", ...).
    # This order is the line index `a` in the models. Files without a number come last.
    sort!(files, by = f -> begin
    name = basename(f)
    m = match(r"^\d+", name)
    m === nothing ? typemax(Int) : parse(Int, m.match)
    end)
    lines = Vector{Line}()
    #println(files)
    for file in files
        # Read JSON file
        data = JSON3.read(file)
        
        data = convert_symbols_to_strings(Dict(data))
        
        # Parse and validate Line object
        push!(lines, parse_line(((Dict(data)))))
    end
    
    return lines
end




# -----------------------------------------------------------------------------
# Load the lines
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
lines_folder = joinpath(process_data_dir, "lines")  # Path to the lines folder

#print(lines_folder)
# Load lines and find unique carriers. The carriers of the network are not given
# separately: they are all carriers that appear on at least one line. The order of
# `carriers` is the carrier index `f` in the models.
lines = load_lines_from_folder(lines_folder)
carriers = unique(collect(line.carrier for line in lines))

#println("Unique carriers: ", carriers)

#carriers = ["electricity", "heat", "hydrogen","water"]
# Get the number of carriers (N)
N_carriers = length(carriers)

# Create the NxN matrix of combined carriers. Element [i,j] is the name
# "<input carrier i>_<output carrier j>"; the diagonal holds the carrier name itself.
# The unit prep files use these names to build the conversion matrices. Because the
# names are split at "_" again, carrier names must not contain an underscore.
carrier_matrix = fill("", N_carriers, N_carriers)

# Fill the matrix with combinations
for i in 1:N_carriers
    for j in 1:N_carriers
        if i == j
            carrier_matrix[i, j] = "$(carriers[i])"  # e.g., "electricity"
        else
            carrier_matrix[i,j] = "$(carriers[i])_$(carriers[j])"  # e.g., "electricity_hydrogen"
        end
    end
end

# L is the largest lag in the network and `lags` all lags 0, 1, ..., L (length L+1)
L = maximum(lines -> lines.lag, lines)
lags = collect(0:L)

println("$(length(lines)) Lines are loaded")

