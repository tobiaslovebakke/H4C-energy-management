# Multi-state units

A multi-state unit is a conversion unit that is in exactly one of several
**states** in every time step. Each state is of one of three types:

- **off**: the unit is off; it has no inputs and no outputs;
- **standby**: the unit is kept ready, e.g. warm, without producing; it may have
  a constant consumption;
- **on**: the unit produces, within the operating range of that state.

A unit can have several states of the same type, e.g. two on-states with
different efficiencies. Within an on-state, every input and output is a linear
function of the **main output** of the unit, e.g. the hydrogen production of an
electrolyser. Typical examples are electrolysers and furnaces that need to be
kept warm.

Each multi-state unit is described by one JSON file in this folder.

## Required fields

Every multi-state unit file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"multi_unit"` |
| `name` | text | Name of the unit, used as column name in the results |
| `node` | whole number | Node at which the unit is located |
| `main_output` | text | Carrier of the main output, e.g. `"hydrogen"` |
| `num_states` | whole number | Number of states |
| `states` | list of text | Type of each state: `"off"`, `"standby"` or `"on"` |
| `min_input` | object | Minimum input of each carrier in each state |
| `max_input` | object | Maximum input of each carrier in each state |
| `min_output` | object | Minimum output of each carrier in each state |
| `max_output` | object | Maximum output of each carrier in each state |
| `cost_operating` | object | Operating cost per unit of output, per carrier |

`min_input`, `max_input`, `min_output` and `max_output` contain, per carrier, a
list with one value per state, in the order of `states`. Carriers that are not
listed get the value 0 in every state. `cost_operating` contains one value per
output carrier.

An electrolyser at node 4 that converts electricity into hydrogen, with an
off-state, a standby state with a consumption of 0.5 and an on-state:

```json
{
    "module": "multi_unit",
    "name": "electrolyser",
    "node": 4,
    "main_output": "hydrogen",
    "num_states": 3,
    "states": ["off", "standby", "on"],
    "min_input": {
        "electricity": [0.0, 0.5, 2.0]
    },
    "max_input": {
        "electricity": [0.0, 0.5, 10.0]
    },
    "min_output": {
        "hydrogen": [0.0, 0.0, 0.4]
    },
    "max_output": {
        "hydrogen": [0.0, 0.0, 2.0]
    },
    "cost_operating": {
        "hydrogen": 1.0
    }
}
```

In the on-state the electrolyser produces between 0.4 and 2 units of hydrogen,
using between 2 and 10 units of electricity; in between, the electricity use is
interpolated linearly (e.g. 6 units of electricity for 1.2 units of hydrogen).

## Optional fields

These fields can be added when needed; otherwise the default is used.

| Field | Type | Default | Description |
|---|---|---|---|
| `start_stop_cost` | list of 2 numbers | `[0, 0]` | Cost of one hot cycle (on ↔ standby) and of one cold cycle (on ↔ off), in that order, charged when the unit stops |
| `min_up_time` | whole number | `0` | Minimum number of time steps the unit stays on after a (hot or cold) start |
| `min_down_time` | whole number | `0` | Minimum number of time steps the unit stays off after a cold stop |
| `ramp_up` | object | `M_unit` (no limit) | Maximum increase of the output per time step, per carrier |
| `ramp_down` | object | `M_unit` (no limit) | Maximum decrease of the output per time step, per carrier |
| `start_up_time` | list of 2 numbers | `[0, 0]` | Read, but not used by the current model |

`ramp_up` and `ramp_down` contain one value per output carrier, e.g.
`{"hydrogen": 0.5}`. Carriers that are not listed have no ramp limit. The
"no limit" default is the constant `M_unit` set in the main script (10 000);
if your outputs can change by more than that per time step, increase `M_unit`.

The same electrolyser with start/stop costs, a minimum up time and a ramp limit:

```json
{
    "module": "multi_unit",
    "name": "electrolyser",
    "node": 4,
    "main_output": "hydrogen",
    "num_states": 3,
    "states": ["off", "standby", "on"],
    "min_input": {
        "electricity": [0.0, 0.5, 2.0]
    },
    "max_input": {
        "electricity": [0.0, 0.5, 10.0]
    },
    "min_output": {
        "hydrogen": [0.0, 0.0, 0.4]
    },
    "max_output": {
        "hydrogen": [0.0, 0.0, 2.0]
    },
    "cost_operating": {
        "hydrogen": 1.0
    },
    "start_stop_cost": [20.0, 150.0],
    "min_up_time": 3,
    "ramp_up": {
        "hydrogen": 0.5
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

**How the states are specified.**
- *On-states*: the inputs and outputs are linear in the main output, along the
  straight line through the minimum point (`min_input`, `min_output`) and the
  maximum point (`max_input`, `max_output`) of that state. The minimum and
  maximum of the main output must therefore differ in every on-state; otherwise
  the unit cannot produce in that state.
- *Standby states*: the main output is 0, and the input is a constant
  consumption equal to `min_input`. Set `min_input` and `max_input` to the same
  value and all outputs to 0.
- *Off-states*: set all inputs and outputs to 0.

**Order of the states.** List an off-state first. The model assumes that the unit
is off and in its first state at the start of the first optimisation. Every unit
should also have at least one off-state: the model uses it internally to give
units with fewer states the same number of states as the unit with the most
states.

**State transitions.**
- Moving between standby and on is a *hot* start or stop; moving between off and
  on is a *cold* start or stop.
- Standby can only be reached from, and left to, an on-state: a direct change
  between off and standby is not possible.
- At most one start or stop can happen per time step.
- Changes between states of the same type (e.g. two on-states) are free.

**Minimum up and down times.** After a hot or cold start the unit stays on for at
least `min_up_time` time steps; after a cold stop it stays in an off-state for at
least `min_down_time` time steps.

**Here-and-now decisions.** In the here-and-now time steps, whether the unit is on
or not is the same in all scenarios. Which on-state it is in, and how much it
produces, may still differ per scenario.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A multi-state unit adds its operating cost and its start/stop costs:

$$
\sum_{w} \pi_w \sum_{t} \Big( \sum_{f} \text{cost\_operating}_f \cdot \text{output}_{f,t,w} \; + \; c_{\text{hot}} \cdot \text{hot\_stop}_{t,w} \; + \; c_{\text{cold}} \cdot \text{cold\_stop}_{t,w} \Big)
$$

where $\pi_w$ is the probability of scenario $w$, $\text{output}_{f,t,w}$ the
total flow of carrier $f$ on the lines leaving the unit's node in time step $t$,
$c_{\text{hot}}$ and $c_{\text{cold}}$ the first and second value of
`start_stop_cost`, and $\text{hot\_stop}_{t,w}$ and $\text{cold\_stop}_{t,w}$
equal 1 in the time steps in which the unit goes from on to standby or from on to
off.

- The operating cost is charged per unit of **output**, per carrier.
- Each start/stop cost is charged once per cycle, in the time step in which the
  unit stops.
- The inputs, including the standby consumption, have no cost of their own in the
  unit: their cost comes from where they are produced, e.g. the price of the
  source that supplies them or the cost of the lines that transport them.

**Operating cost or line cost.** `cost_operating` is a convenient way to put a
cost, e.g. a tax or a wear cost, on all output of one carrier of the unit. The
same effect can be obtained by giving all lines that leave the unit with that
carrier the same `cost` (see the lines folder). Which of the two to use is up to
the modeller; do not use both for the same cost, or it is counted twice.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_electrolyser.json`,
`2_furnace.json`. The files are read in the order of these numbers, which
determines the index of each unit in the model. Files without a number are read
last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_z_multi_on.csv` | 1 if the unit is in an on-state |
| `Results/<simulation_name>_z_multi_state.csv` | 1 for the active state; columns are named `<name>_<state number>` |
| `Results/<simulation_name>_x_multi_main.csv` | Main output in each state; columns are named `<name>_<state number>` |
| `Results/<simulation_name>_z_multi_h_start.csv` | 1 in the time steps with a hot start (standby → on) |
| `Results/<simulation_name>_z_multi_h_stop.csv` | 1 in the time steps with a hot stop (on → standby) |
| `Results/<simulation_name>_z_multi_c_start.csv` | 1 in the time steps with a cold start (off → on) |
| `Results/<simulation_name>_z_multi_c_stop.csv` | 1 in the time steps with a cold stop (on → off) |

The inputs and outputs of the unit are the flows on its lines, in
`Results/<simulation_name>_x.csv`.
