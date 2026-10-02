# Units

A unit is a conversion unit with fixed conversion factors: it converts one or more
input carriers into one or more output carriers, for example a heat pump that
converts electricity into heat, or an electrolyser that converts electricity into
hydrogen. A unit can be switched on and off; when it is on, its inputs and outputs
lie between their minimum and maximum, and when it is off they are zero.

For units whose efficiency depends on the operating point or on the state of the
system, see the CG units, multi-state units and segment units.

Each unit is described by one JSON file in this folder.

## Required fields

Every unit file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"unit"` |
| `name` | text | Name of the unit, used as column name in the results |
| `node` | whole number | Node at which the unit is located |
| `min_input` | object | Minimum input of each carrier while the unit is on |
| `max_input` | object | Maximum input of each carrier while the unit is on |
| `min_output` | object | Minimum output of each carrier while the unit is on |
| `max_output` | object | Maximum output of each carrier while the unit is on |
| `cost_operating` | object | Operating cost per unit of output, per carrier |

All five objects contain one value per carrier, e.g. `{"electricity": 3.0}`.
Carriers that are not listed get the value 0.

A heat pump at node 2 with an efficiency (coefficient of performance) of 3, which
can use between 1 and 3 units of electricity per time step:

```json
{
    "module": "unit",
    "name": "heat_pump",
    "node": 2,
    "min_input": {
        "electricity": 1.0
    },
    "max_input": {
        "electricity": 3.0
    },
    "min_output": {
        "heat": 3.0
    },
    "max_output": {
        "heat": 9.0
    },
    "cost_operating": {
        "heat": 0.5
    }
}
```

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
`{"heat": 3.0}`. Carriers that are not listed have no ramp limit. The
"no limit" default is the constant `M_unit` set in the main script (10 000);
if your outputs can change by more than that per time step, increase `M_unit`.

The same heat pump with a start/stop cost, a minimum up time and a ramp limit:

```json
{
    "module": "unit",
    "name": "heat_pump",
    "node": 2,
    "min_input": {
        "electricity": 1.0
    },
    "max_input": {
        "electricity": 3.0
    },
    "min_output": {
        "heat": 3.0
    },
    "max_output": {
        "heat": 9.0
    },
    "cost_operating": {
        "heat": 0.5
    },
    "start_stop_cost": 25.0,
    "min_up_time": 3,
    "ramp_up": {
        "heat": 3.0
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

**Conversion factors.** The conversion factors are not given directly, but derived
from the maximum capacities: the factor from input carrier `f` to output carrier
`g` is `max_output[g] / max_input[f]`. In the example, 9 / 3 = 3 units of heat per
unit of electricity. Choose `min_input` and `min_output` consistent with this
factor (in the example, 1 × 3 = 3).

**Several inputs or outputs.** Every input–output pair must satisfy its factor,
so a unit with several inputs or outputs uses and produces them in fixed
proportions. For example, an electrolyser with `max_input`
`{"electricity": 10, "water": 20}` and `max_output` `{"hydrogen": 2}` always uses
2 units of water per unit of electricity.

**Inputs are needed.** The conversion only links outputs to inputs. A unit
without any input carrier is not limited by a conversion and produces its outputs
for free; use a source for that instead.

**Always-on units.** A unit without start/stop cost, start-up time and minimum
input or output does not need on/off decisions. The model then fixes it to "on",
which makes the problem smaller without changing the result: with minimum loads
of 0 it can still produce nothing.

**Here-and-now decisions.** In the here-and-now time steps, whether the unit is on
or not is the same in all scenarios. How much it produces may still differ per
scenario.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A unit adds its operating cost and its start/stop cost:

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
`2_electrolyser.json`. The files are read in the order of these numbers, which
determines the index of each unit in the model. Files without a number are read
last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_z.csv` | On/off status of each unit (1 = on) |
| `Results/<simulation_name>_z_start.csv` | 1 in the time steps in which a unit starts |
| `Results/<simulation_name>_z_stop.csv` | 1 in the time steps in which a unit stops |

The inputs and outputs of the unit are the flows on its lines, in
`Results/<simulation_name>_x.csv`.
