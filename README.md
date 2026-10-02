# H4C model

A two-stage stochastic optimisation model for the operational energy management scheduling
of hubs for circularity (H4C), but can also be applied for
multi-carrier energy and material networks, written in Julia with
[JuMP](https://jump.dev).

The model describes a network of sources, conversion units, storages and demands
connected by lines, each line carrying one carrier (e.g. electricity, heat,
hydrogen, water). Given scenarios for uncertain inputs such as renewable
generation and prices, it decides the flows, storage levels and on/off schedules
that minimise the expected operating cost minus the expected revenue. The
decisions for the first time steps (here-and-now) are the same in all scenarios;
the later decisions may adapt to each scenario.

The model is originally made for hubs for circularity, where energy is 
scheduled alongisde industrial symbiosis, that can both be energy- and
more material-based. It is developed as part of the IS2H4C project.

## Citation

If you use this model in your research, please cite:

> **[TODO: authors, title, journal, year, DOI]**

```bibtex
[TODO: BibTeX entry]
```

The mathematical formulation of the model is described in this publication.

## Features

The network can contain the following components:

| Component | Description |
|---|---|
| Line | Directed connection between two nodes that transports one carrier, optionally with a time delay (lag) |
| Source | Supply of a carrier, e.g. a PV park, wind turbine or grid connection, with a price and a (scenario-dependent) availability |
| Unit | Conversion unit with fixed conversion factors, minimum/maximum load, ramp limits, start/stop costs and minimum up/down times |
| Cogeneration (CG) unit | Unit whose operating region is the convex hull of a set of extreme points, e.g. a combined heat and power plant |
| Multi-state unit | Unit with several operating states ("off", "standby", "on"), each with its own operating range |
| Segment unit | Unit whose conversion factors depend on the level of a storage |
| Transport unit | Fleet of vehicles that ships a carrier over routes in discrete trips |
| Storage | Storage of a carrier with capacities, efficiencies and losses |
| Demand | Demand for a carrier with a price; either fixed or shiftable in time |

## Requirements

- [Julia](https://julialang.org/downloads/) 1.10 or newer
- A mixed-integer linear programming (MILP) solver supported by JuMP. By default
  the model uses [Gurobi](https://www.gurobi.com), which requires a licence (free
  for academic use). The open-source solver [HiGHS](https://highs.dev) can be used
  instead, but is considerably slower on large instances.

## Installation

1. Download or clone this repository.
2. Open a terminal in the repository folder and install the required packages:

   ```
   julia --project=. -e "using Pkg; Pkg.instantiate()"
   ```

3. To use HiGHS (or another solver) instead of Gurobi, add its package:

   ```
   julia --project=. -e "using Pkg; Pkg.add(\"HiGHS\")"
   ```

   and select it in the user settings of the main script (see below).

## Getting started

The repository does not contain a network: the folders `process_data/` and
`time_series_data/` are empty. Before running the model you describe your own
system in these folders.

1. **Describe the network.** Give every location in your system a node number.
   Each component (source, unit, storage, demand, ...) is placed at a node, and
   lines connect the nodes. In `process_data/`, create the subfolders listed in
   [Input data](#input-data) and add one JSON file per component. All subfolders
   must exist, even if they stay empty.

2. **Add the time series.** For every JSON field that refers to a CSV file
   (e.g. the output of a PV source or a demand profile), place that file in
   `time_series_data/`. Fields that are constant can be given as a number in
   the JSON file instead.

3. **Adjust the settings.** Open `EM_in_H4C_model_main.jl` and adjust the
   **USER SETTINGS** at the top:

   | Setting | Meaning |
   |---|---|
   | `simulation_name` | Name of the run, used in the names of the result files |
   | `T_opti` | Number of time steps in the optimisation horizon |
   | `Scenarios` | Number of scenarios |
   | `probabilities` | Probability of each scenario (one value per scenario, summing to 1) |
   | `time_limit` | Time limit of the solver in seconds (`nothing` = no limit) |
   | `threads` | Number of solver threads (0 = solver default) |
   | `nodes` | Memory in GB after which Gurobi or other solver writes branch-and-bound nodes to disk |
   | `optimizer` | The solver, e.g. `Gurobi.Optimizer` or `HiGHS.Optimizer` |

   The number of rows in the CSV files must be at least `T_opti`, and files with
   one column per scenario must have exactly `Scenarios` columns.

4. **Run the model:**

   ```
   julia EM_in_H4C_model_main.jl
   ```

   or, from the Julia REPL, `include("EM_in_H4C_model_main.jl")`. While reading
   the input, the model reports how many components of each type were loaded;
   check that these numbers match your network.

5. **Inspect the results** in the folder `Results/` (see [Output](#output)).

## Input data

The network is described by JSON files in the folder `process_data/`, with one
subfolder per component type and one file per component:

```
process_data/
├── lines/
├── sources/
├── units/
├── cg_units/
├── multi_units/
├── segment_units/
├── transport_units/
├── storages/
└── demands/
```

All subfolders must exist, but may be empty if the network has no components of
that type. Files are read in the order of the number at the start of their name
(`1_grid.json`, `2_pv.json`, ...); this order determines the index of each
component in the model.

Example of a line:

```json
{
    "module": "line",
    "name": "grid_to_electrolyser",
    "from": 1,
    "to": 2,
    "carrier": "electricity",
    "max_cap": 10.0
}
```

A full description of each component type and its fields is given in the README
file in its subfolder of `process_data/`.

The model does not convert units: all values must be given in consistent units
(e.g. MW for flows and capacities, MWh for storage contents and €/MWh for
prices, with one time step of one hour).

### Time series

Some fields can vary over time and per scenario. They can be given either as a
**number**, which is then used for every time step and every scenario, or as the
**name of a CSV file** in the folder `time_series_data/`:

| Component | Fields that accept a time series |
|---|---|
| Source | `output`, `price` |
| Demand | `demand`, `price`, `flex_factor` |
| Storage | `a_loss`, `b_loss` |

For example, a PV source can refer to its profile with
`"output": "pv_profile.csv"`, while a constant price is simply written as
`"price": 0.05`. A source's `output` can also be `"M"` for an unlimited supply.

A time-series file must follow these rules:

- **No header.** The first line already contains the values of the first time
  step.
- **One row per time step**, starting at time step 1. The file needs at least
  `T_opti` rows; additional rows are ignored.
- **One column, or one column per scenario.** With one column, the same series is
  used in every scenario. With several columns, there must be exactly one column
  per scenario (`Scenarios` in the main script), in the order of the scenarios.
- **Only numbers**, separated by commas, with a point as decimal separator.

Example of a file with three scenarios and the first four time steps:

```
0.0,0.0,0.0
1.2,0.8,1.5
3.4,2.9,4.1
5.0,4.2,5.8
```

The model checks the number of columns of every time-series file when it reads it
and stops with an error message if it does not match the number of scenarios.

## Output

The results are written to `Results/`:

- `<simulation_name>_summary.csv`: solve status, objective value, objective of
  the here-and-now time steps, solve time and MIP gap.
- `<simulation_name>_<variable>.csv`: one file per decision variable, e.g. `x`
  (flows on the lines), `y` (storage levels) and `z` (on/off status of the
  units). Each row is one combination of scenario and time step; each column is
  one component, named after the `name` in its JSON file.

See [Results/README Results.md](Results/README%20Results.md) for a description of
all result files and variables.

## Rolling-horizon simulations

`EM_in_H4C_model_main_RH_template.jl` is a starting point for rolling-horizon
simulations, in which the stochastic model is solved repeatedly as the horizon
moves forward and its here-and-now decisions are evaluated against realised
data. The template sets up the models and the first-stage decisions to be fixed;
the loop itself is described step by step in comments, to be completed for your
own data, if needed.

## Repository structure

| File | Purpose |
|---|---|
| `EM_in_H4C_model_main.jl` | Main script: runs the stochastic model once and saves the results |
| `EM_in_H4C_model_main_RH_template.jl` | Template for rolling-horizon simulations |
| `EM_in_H4C_model_stochastic.jl` | The two-stage stochastic model |
| `EM_in_H4C_model_realisation.jl` | Realisation model: evaluates fixed first-stage decisions against realised data |
| `H4C_preprocessing.jl` | Reads the network and builds the initial state |
| `*_prep.jl` | Readers for the individual component types |
| `process_data/` | Network description (JSON) |
| `time_series_data/` | Time series (CSV) |
| `Results/` | Output |

## Licence

**[TODO: licence, e.g. MIT]**

## Contact

Tobias Løvebakke Nielsen, University of Twente, t.l.nielsen@utwente.nl
Daniela Guericke, University of Twente, d.guericke@utwente.nl


## Acknowledgements

This model is part of the project IS2H4C (Sustainable Circular Economy Transition: From Industrial Symbiosis to Hubs for Circularity) which has received funding from the European Union’s HORIZON Research and Innovation Actions programme under grant agreement number 101138473.
