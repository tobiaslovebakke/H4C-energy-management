# Segment units

A segment unit is a conversion unit whose conversion factors and capacities depend
on the state of another variable in the model. The range of that variable is
divided into **segments**, and each segment has its own conversion factors and
bounds. When the unit is on, exactly one segment is active: the one whose range
contains the current value of the variable.

The variable that selects the segment is called the **segment determiner**. In
the current implementation, the segment determiner is always the level of a
storage. Other types of determining variables may be added in future versions.

A typical example is a heat pump that extracts heat from a thermal storage: the
warmer (fuller) the storage, the higher the efficiency of the heat pump.

Each segment unit is described by one JSON file in this folder.

## Required fields

Every segment unit file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"segment_unit"` |
| `name` | text | Name of the unit, used as column name in the results |
| `node` | whole number | Node at which the unit is located |
| `num_segments` | whole number | Number of segments |
| `segment_determiner` | whole number | The variable that selects the segment; currently the number of a storage (see below) |
| `min_state` | list of numbers | Lower bound of the determining variable for each segment |
| `max_state` | list of numbers | Upper bound of the determining variable for each segment |
| `min_input` | object | Minimum input of each carrier in each segment |
| `max_input` | object | Maximum input of each carrier in each segment |
| `min_output` | object | Minimum output of each carrier in each segment |
| `max_output` | object | Maximum output of each carrier in each segment |
| `cost_operating` | object | Operating cost per unit of output, per carrier |

`min_state`, `max_state` and the lists in `min_input`, `max_input`, `min_output`
and `max_output` contain one value per segment, in the same order. Carriers that
are not listed get the value 0 in every segment. `cost_operating` contains one
value per output carrier.

In the current implementation, `segment_determiner` is the position of a storage
in the storages folder: 1 for the first storage file, 2 for the second, and so on
(see the file names in the storages folder). `min_state` and `max_state` are then
storage levels.

A heat pump at node 5 that uses electricity to upgrade low-temperature heat
(`lowheat`) from storage 1 into high-temperature heat (`highheat`). It has two
segments: while the level of storage 1 is below 50, its efficiency (heat output
per unit of electricity) is 2.5; above 50 it is 4.

```json
{
    "module": "segment_unit",
    "name": "heat_pump",
    "node": 5,
    "num_segments": 2,
    "segment_determiner": 1,
    "min_state": [0.0, 50.0],
    "max_state": [50.0, 100.0],
    "min_input": {
        "electricity": [0.8, 0.5],
        "lowheat":     [1.2, 1.5]
    },
    "max_input": {
        "electricity": [4.0, 2.5],
        "lowheat":     [6.0, 7.5]
    },
    "min_output": {
        "highheat": [2.0, 2.0]
    },
    "max_output": {
        "highheat": [10.0, 10.0]
    },
    "cost_operating": {
        "highheat": 0.5
    }
}
```

Storage 1 stores `lowheat` and is connected to the heat pump by a line from the
storage's node to node 5.

## Optional fields

These fields can be added when needed; otherwise the default is used.

| Field | Type | Default | Description |
|---|---|---|---|
| `start_stop_cost` | number | `0` | Cost of one start/stop cycle, charged when the unit is switched off |
| `min_up_time` | whole number | `0` | Minimum number of time steps the unit stays on after a start |
| `min_down_time` | whole number | `0` | Minimum number of time steps the unit stays off after a stop |
| `ramp_up` | object | `M_unit` (no limit) | Maximum increase of the output per time step, per carrier |
| `ramp_down` | object | `M_unit` (no limit) | Maximum decrease of the output per time step, per carrier |
| `start_up_time` | whole number | `0` | Read, but not used by the current model |

`ramp_up` and `ramp_down` contain one value per output carrier, e.g.
`{"highheat": 3.0}`. Carriers that are not listed have no ramp limit. The
"no limit" default is the constant `M_unit` set in the main script (10 000);
if your outputs can change by more than that per time step, increase `M_unit`.

The same heat pump with a start/stop cost, a minimum up time and a ramp limit:

```json
{
    "module": "segment_unit",
    "name": "heat_pump",
    "node": 5,
    "num_segments": 2,
    "segment_determiner": 1,
    "min_state": [0.0, 50.0],
    "max_state": [50.0, 100.0],
    "min_input": {
        "electricity": [0.8, 0.5],
        "lowheat":     [1.2, 1.5]
    },
    "max_input": {
        "electricity": [4.0, 2.5],
        "lowheat":     [6.0, 7.5]
    },
    "min_output": {
        "highheat": [2.0, 2.0]
    },
    "max_output": {
        "highheat": [10.0, 10.0]
    },
    "cost_operating": {
        "highheat": 0.5
    },
    "start_stop_cost": 30.0,
    "min_up_time": 2,
    "ramp_up": {
        "highheat": 3.0
    }
}
```

## Details

**Connection to the network.** The unit receives its inputs over the lines that
end at its node and delivers its outputs over the lines that start at its node.
For every input carrier there must be a line into the node, and for every output
carrier a line out of the node. Give each unit its own node: all lines at a node
are attributed to the component at that node. If a line into the unit has a lag,
the unit uses the input when it arrives.

**Conversion factors.** The conversion factors are not given directly, but
derived per segment from the maximum capacities: the factor from input carrier
`f` to output carrier `g` in segment `s` is `max_output[g][s] / max_input[f][s]`.
In the example, segment 1 gives 10 / 4 = 2.5 units of high-temperature heat per
unit of electricity and segment 2 gives 10 / 2.5 = 4. Choose `min_input` and
`min_output` consistent with these factors (in the example, 0.8 × 2.5 = 2 and
0.5 × 4 = 2). If a unit has several inputs that produce the same output, each
input–output pair must satisfy its factor, so the inputs are used in fixed
proportions: in segment 1 of the example, every 10 units of high-temperature heat
take 4 units of electricity and 6 units of low-temperature heat.

**Segments and the determining variable.** When the unit is on, the value of the
determining variable in the same time step must lie between `min_state` and
`max_state` of the active segment. When the unit is off, the variable is not
restricted by the segments. Make the segments cover the full range of the
variable without gaps (adjacent segments may share their boundary, as in the
example); while the variable is in a gap, the unit cannot be on.

**Different numbers of segments.** Units may have different numbers of segments.
The model internally extends units with fewer segments by repeating their first
segment, which does not change their behaviour.

**Initial state.** At the start of the first optimisation the unit is off, and
its segment is the one that contains the `initial_level` of the determining
storage.

**Here-and-now decisions.** In the here-and-now time steps, whether the unit is on
or not is the same in all scenarios. Which segment is active, and how much it
produces, may still differ per scenario.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A segment unit adds its operating cost and its start/stop cost:

$$
\sum_{w} \pi_w \sum_{t} \Big( \sum_{f} \text{cost\_operating}_f \cdot \text{output}_{f,t,w} \; + \; \text{start\_stop\_cost} \cdot \text{stop}_{t,w} \Big)
$$

where $\pi_w$ is the probability of scenario $w$, $\text{output}_{f,t,w}$ the
total flow of carrier $f$ on the lines leaving the unit's node in time step $t$,
and $\text{stop}_{t,w}$ equals 1 in the time steps in which the unit is switched
off.

- The operating cost is charged per unit of **output**, per carrier.
- The start/stop cost is charged once per on/off cycle, in the time step in which
  the unit stops.
- The inputs have no cost of their own in the unit: their cost comes from where
  they are produced, e.g. the price of the source that supplies them or the cost
  of the lines that transport them.

**Operating cost or line cost.** `cost_operating` is a convenient way to put a
cost, e.g. a tax or a wear cost, on all output of one carrier of the unit. The
same effect can be obtained by giving all lines that leave the unit with that
carrier the same `cost` (see the lines folder). Which of the two to use is up to
the modeller; do not use both for the same cost, or it is counted twice.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_heat_pump.json`,
`2_heat_pump_backup.json`. The files are read in the order of these numbers,
which determines the index of each unit in the model. Files without a number are
read last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_z_segment_on.csv` | On/off status of each unit (1 = on) |
| `Results/<simulation_name>_z_segment_start.csv` | 1 in the time steps in which a unit starts |
| `Results/<simulation_name>_z_segment_stop.csv` | 1 in the time steps in which a unit stops |
| `Results/<simulation_name>_z_segment_state.csv` | 1 for the active segment; columns are named `<name>_<segment number>` |
| `Results/<simulation_name>_x_segment_in.csv` | Input per segment and carrier; columns are named `<name>_<segment number>_<carrier number>` |

The inputs and outputs of the unit are the flows on its lines, in
`Results/<simulation_name>_x.csv`. The carrier numbers follow the order in which
the carriers first appear in the line files.
