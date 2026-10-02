# Results

When `EM_in_H4C_model_main.jl` has solved the model, it writes the results to
this folder. All file names start with the `simulation_name` from the user
settings; files of an earlier run with the same name are overwritten.

The values are in the same units as the input data.

## Summary

`<simulation_name>_summary.csv` contains one row with the outcome of the solve:

| Column | Description |
|---|---|
| `status` | Termination status of the solver, e.g. `OPTIMAL` or `TIME_LIMIT` |
| `objective` | Expected objective value over the whole horizon (`T_opti` time steps): expected cost minus expected revenue |
| `objective_hn` | Expected objective value over the here-and-now time steps (`T_hn`) only |
| `solve_time` | Solve time in seconds |
| `mip_gap` | Relative gap between the best solution and the best bound; `NaN` if the solver does not report it |

The same information is printed at the end of the run.

If the solver found no feasible solution (e.g. the problem is infeasible, or the
time limit was reached before a first solution), only the summary is written,
with `NaN` as objective values.

## Decision variables

For each decision variable there is one file, `<simulation_name>_<variable>.csv`.

**Rows.** Every row is one combination of scenario and time step. The first two
columns, `Scenario` and `Time`, give that combination; all time steps of
scenario 1 come first, then those of scenario 2, and so on.

**Columns.** Every further column is one element of the variable, named after
the `name` field of the component in its JSON file, e.g. `heat_pump`. For
variables with an additional index, that index is appended as a number, e.g.
`chp_2` for extreme point 2 of the CG unit `chp`. If two components have the same
name, the index of the component is appended to make the column names unique.

Files are only written for component types that are present in the network.

| File (`<variable>`) | Component | Content | Extra index in the column name |
|---|---|---|---|
| `x` | Lines | Flow sent over each line | – |
| `y` | Storages | Content of each storage at the end of the time step | – |
| `z` | Units | On/off status (1 = on) | – |
| `z_start` | Units | 1 in the time step in which the unit starts | – |
| `z_stop` | Units | 1 in the time step in which the unit stops | – |
| `z_cg` | CG units | On/off status (1 = on) | – |
| `z_cg_start` | CG units | 1 in the time step in which the unit starts | – |
| `z_cg_stop` | CG units | 1 in the time step in which the unit stops | – |
| `alpha` | CG units | Weight of each extreme point | extreme point |
| `z_multi_on` | Multi-state units | 1 if the unit is in an on-state | – |
| `z_multi_state` | Multi-state units | 1 for the active state | state |
| `x_multi_main` | Multi-state units | Main output in each state | state |
| `z_multi_h_start` | Multi-state units | 1 at a hot start (standby → on) | – |
| `z_multi_h_stop` | Multi-state units | 1 at a hot stop (on → standby) | – |
| `z_multi_c_start` | Multi-state units | 1 at a cold start (off → on) | – |
| `z_multi_c_stop` | Multi-state units | 1 at a cold stop (on → off) | – |
| `z_segment_on` | Segment units | On/off status (1 = on) | – |
| `z_segment_start` | Segment units | 1 in the time step in which the unit starts | – |
| `z_segment_stop` | Segment units | 1 in the time step in which the unit stops | – |
| `z_segment_state` | Segment units | 1 for the active segment | segment |
| `x_segment_in` | Segment units | Input per segment and carrier | segment, carrier |
| `z_transport` | Transport units | 1 if a trip departs on the route | route |
| `v_up` | Transferable demands | Increase of the demand | – |
| `v_down` | Transferable demands | Decrease of the demand | – |

The numbers of the extra indices are:

- **extreme point, state, segment**: the position in the lists of the component's
  JSON file (1 for the first value, 2 for the second, …);
- **route**: the position of the route line among the lines that start at the
  depot, in the order of the line files;
- **carrier**: the position of the carrier in the order in which the carriers
  first appear in the line files.

Units with fewer extreme points, states, segments or routes than the largest unit
of their type also have columns for the missing ones; these contain copies of
another point, state or segment, or zeros for missing routes.

## Reading the results

**Inputs and outputs of components** are not stored separately: they are the
flows on the component's lines in `x`. For example, the output of a unit is the
sum of the flows on the lines that start at its node.

**Here-and-now time steps.** In the first `T_hn` time steps, the here-and-now
decisions (on/off status of the units, transport trips and the amounts taken
from here-and-now sources) are the same in all scenarios. The other values may
differ per scenario. In a rolling-horizon setting, these first `T_hn` time steps
are the decisions that are actually implemented.

**Scenarios.** To obtain an expected value of a result, weight the scenarios with
the probabilities set in the main script.
