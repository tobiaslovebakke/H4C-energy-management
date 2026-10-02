# =============================================================================
# storage_prep.jl
#
# Reads the storages from the JSON files in process_data/storages.
#
# Requires line_prep.jl and the globals `T_opti` (number of time steps) and
# `Scenarios` (number of scenarios).
#
# JSON fields of a storage (one file per storage)
#   required: "module" (= "storage"), "name", "node", "carrier", "energy_cap"
#   optional: "charge_cap" (default energy_cap), "discharge_cap" (default charge_cap),
#             "charge_eff" (1), "discharge_eff" (1), "a_loss" (0), "b_loss" (0),
#             "initial_level" (0)
# "a_loss" and "b_loss" are either a number (constant over time and scenarios) or
# the name of a CSV file without header in time_series_data, with one row per time
# step and either one column (used for all scenarios) or one column per scenario.
#
# The storage level in the models develops as
#   level[t] = level[t-1] * (1 - a_loss[t]) + b_loss[t] + charge_eff * inflow - outflow / discharge_eff
# =============================================================================

mutable struct Storage
    name::String              # Unit Name
    node::Int64                 # Unit node
    carrier::String  # energy carrier
    energy_cap::Float64        # energy capacity
    charge_cap::Float64          # charge capacity
    discharge_cap::Float64        # discharge capacity
    charge_eff::Float64       # charge efficiency
    discharge_eff::Float64    # discharge efficiency
    a_loss::Matrix{Float64}   # Fraction of the content that is lost per time step [time, scenario]
    b_loss::Matrix{Float64}   # Constant change of the content per time step [time, scenario]
    initial_level::Float64 #initial level of storage
end

"""
    parse_storage(json_dict)

Check that `json_dict` (the content of one JSON file) describes a storage, fill in
the default values of the optional fields and return the `Storage`.
"""
function parse_storage(json_dict::Dict{String, Any})
    # Check for required fields
    required_fields = ["module", "name", "node", "carrier", "energy_cap"]
    for field in required_fields
        if !haskey(json_dict, field)
            throw(ArgumentError("Missing required field: $field"))
        end
    end

    # Validate the module type
    if json_dict["module"] != "storage"
        throw(ArgumentError("Invalid module type: $(json_dict["module"]). Expected 'storage'."))
    end
    # Extract required and optional fields
    name = json_dict["name"]
    node = json_dict["node"]
    check_node(node, name, "node")  # The node must be a whole number (defined in line_prep.jl)
    carrier = json_dict["carrier"]
    energy_cap = json_dict["energy_cap"]
    charge_cap = get(json_dict, "charge_cap", energy_cap)
    discharge_cap = get(json_dict, "discharge_cap", charge_cap)
    charge_eff = get(json_dict, "charge_eff", 1.0)
    discharge_eff = get(json_dict, "discharge_eff", 1.0)

    # Loss parameters as [time, scenario] matrices. A number is used for all time
    # steps and scenarios; otherwise the entry is the name of a CSV file.
    a_loss_data = zeros(T_opti,Scenarios)
    b_loss_data = zeros(T_opti,Scenarios)
    if haskey(json_dict, "a_loss")
        if json_dict["a_loss"] isa Number
            for s in 1:Scenarios
                for t in 1:T_opti
                    a_loss_data[t,s] = json_dict["a_loss"]
                end
            end
        else
            # File name: read the time series from the CSV file in time_series_data
            script_dir = @__DIR__  # Directory of this script
            time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
            a_loss_path = joinpath(time_data_dir, json_dict["a_loss"])  # Path to the CSV file 
            df = CSV.read(a_loss_path, DataFrame; header=false)
            # Convert the DataFrame to a matrix
            if ncol(df)==1
                for s in 1:Scenarios
                    a_loss_data[:,s] = Matrix(df)[1:T_opti,1]
                end
            else
                check_scenario_columns(df, Scenarios, name, "a_loss")  # Defined in line_prep.jl
                a_loss_data = Matrix(df)[1:T_opti,:]
            end
        end
    end

    if haskey(json_dict, "b_loss")
        if json_dict["b_loss"] isa Number
            for s in 1:Scenarios
                for t in 1:T_opti
                    b_loss_data[t,s] = json_dict["b_loss"]
                end
            end
        else
            # File name: read the time series from the CSV file in time_series_data
            script_dir = @__DIR__  # Directory of this script
            time_data_dir = joinpath(script_dir, "time_series_data")  # Path to time_series_data folder
            b_loss_path = joinpath(time_data_dir, json_dict["b_loss"])  # Path to the CSV file 
            df = CSV.read(b_loss_path, DataFrame; header=false)
            # Convert the DataFrame to a matrix
            if ncol(df)==1
                for s in 1:Scenarios
                    b_loss_data[:,s] = Matrix(df)[1:T_opti,1]
                end
            else
                check_scenario_columns(df, Scenarios, name, "b_loss")  # Defined in line_prep.jl
                b_loss_data = Matrix(df)[1:T_opti,:]
            end
        end
    end
    
    a_loss = a_loss_data
    b_loss = b_loss_data

    initial_level = get(json_dict, "initial_level", 0.0)
    # Create and return the Unit instance
    return Storage(name, node, carrier, energy_cap, charge_cap, discharge_cap, charge_eff, discharge_eff, a_loss, b_loss, initial_level)
end

"""
    load_storages_from_folder(folder_path)

Read all JSON files in `folder_path` and return them as a vector of `Storage`s.
"""
function load_storages_from_folder(folder_path::String)::Vector{Storage}
    files = glob("*.json", folder_path)
    storages = Vector{Storage}()
    # Sort the files by the number at the start of the file name. This order is the
    # storage index `s` in the models. Files without a number come last.
    sort!(files, by = f -> begin
    name = basename(f)
    m = match(r"^\d+", name)
    m === nothing ? typemax(Int) : parse(Int, m.match)
    end)
    #println(files)
    for file in files
        # Read JSON file
        data = JSON3.read(file)
        
        data = convert_symbols_to_strings(Dict(data))
        
        # Parse and validate Line object
        push!(storages, parse_storage((((data)))))
    end
    
    return storages
end


# -----------------------------------------------------------------------------
# Load the storages
# -----------------------------------------------------------------------------
script_dir = @__DIR__  # Directory of this script
process_data_dir = joinpath(script_dir, "process_data")  # Path to process_data folder
storage_folder = joinpath(process_data_dir, "storages")  # Path to the storages folder
storages = load_storages_from_folder(storage_folder)

println("$(length(storages)) Storages are loaded")

