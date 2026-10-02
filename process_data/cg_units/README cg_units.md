# Cogeneration (CG) units

A cogeneration unit converts one or more input carriers into several output
carriers at the same time, for example a combined heat and power (CHP) plant that
burns gas and produces electricity and heat. Its feasible operating region is
described by a set of **extreme points**: complete operating points with a given
output of every carrier and the corresponding input. When the unit is on, it can
operate at any weighted average (convex combination) of these points; when it is
off, all its inputs and outputs are zero.

Each CG unit is described by one JSON file in this folder.

## Required fields

Every CG unit file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"cg_unit"` |
| `name` | text | Name of the unit, used as column name in the results |
| `node` | whole number | Node at which the unit is located |
| `extreme` | object | Output of each carrier in each extreme point (see below) |
| `fuel` | object | Input of each carrier in each extreme point (see below) |
| `cost_operating` | object | Operating cost per unit of output, per carrier |

`extreme` and `fuel` contain, per carrier, a list with one value per extreme
point. Extreme point 1 is the first value of every list, extreme point 2 the
second, and so on, so all lists must have the same length. `cost_operating`
contains one value per output carrier. Carriers that are not listed get the
value 0.

A CHP unit at node 3 with three extreme points, which consumes gas and produces
electricity and heat:

```json
{
    "module": "cg_unit",
    "name": "chp",
    "node": 3,
    "extreme": {
        "electricity": [2.0, 10.0, 8.0],
        "heat":        [3.0,  8.0, 12.0]
    },
    "fuel": {
        "gas":         [6.0, 25.0, 25.0]
    },
    "cost_operating": {
        "electricity": 5.0
    }
}
```

In extreme point 2, for example, the unit produces 10 units of electricity and 8
units of heat from 25 units of gas. When it operates halfway between points 2
and 3, it produces 9 units of electricity and 10 units of heat from 25 units of
gas.

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
`{"electricity": 4.0}`. Carriers that are not listed have no ramp limit. The
"no limit" default is the constant `M_unit` set in the main script (10 000);
if your outputs can change by more than that per time step, increase `M_unit`.

The same CHP unit with a start/stop cost, a minimum up time and a ramp limit:

```json
{
    "module": "cg_unit",
    "name": "chp",
    "node": 3,
    "extreme": {
        "electricity": [2.0, 10.0, 8.0],
        "heat":        [3.0,  8.0, 12.0]
    },
    "fuel": {
        "gas":         [6.0, 25.0, 25.0]
    },
    "cost_operating": {
        "electricity": 5.0
    },
    "start_stop_cost": 100.0,
    "min_up_time": 4,
    "ramp_up": {
        "electricity": 4.0
    }
}
```

## Details

**Connection to the network.** The unit receives its inputs over the lines that
end at its node and delivers its outputs over the lines that start at its node.
For every carrier in `fuel` there must be a line into the node, and for every
carrier in `extreme` a line out of the node. Give each unit its own node: all
lines at a node are attributed to the component at that node.

**Choosing the extreme points.** The unit can only operate inside the region
spanned by the extreme points, so they also define its minimum load. A unit whose
extreme points all have a positive output cannot run at zero output while it is
on; to stop producing, it has to be switched off.

**Different numbers of extreme points.** Units may have different numbers of
extreme points. The model internally extends units with fewer points by repeating
their first point, which does not change their operating region.

**Lags on input lines.** If a line into the unit has a lag, the unit uses the
input when it arrives, i.e. `lag` time steps after it was sent.

**Ramping.** Ramp limits apply to the outputs. In a time step in which the unit
starts or stops, the limit is widened by the smallest output of that carrier over
all extreme points, so that the unit can reach or leave its operating region.

**Here-and-now decisions.** In the here-and-now time steps, whether the unit is on
or not is the same in all scenarios. Its operating point within the extreme
points may still differ per scenario.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A CG unit adds its operating cost and its start/stop cost:

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
- The inputs (`fuel`) have no cost of their own in the CG unit: their cost comes
  from where they are produced, e.g. the price of the source that supplies the
  fuel, the cost of the lines that transport it, or the operating cost of the
  unit that produces it.

**Operating cost or line cost.** `cost_operating` is a convenient way to put a
cost, e.g. a tax or a wear cost, on all output of one carrier of the unit. The
same effect can be obtained by giving all lines that leave the unit with that
carrier the same `cost` (see the lines folder). Which of the two to use is up to
the modeller; do not use both for the same cost, or it is counted twice.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_chp.json`, `2_chp_backup.json`. The
files are read in the order of these numbers, which determines the index of each
unit in the model. Files without a number are read last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_z_cg.csv` | On/off status of each unit (1 = on) |
| `Results/<simulation_name>_z_cg_start.csv` | 1 in the time steps in which a unit starts |
| `Results/<simulation_name>_z_cg_stop.csv` | 1 in the time steps in which a unit stops |
| `Results/<simulation_name>_alpha.csv` | Weight of each extreme point; columns are named `<name>_<extreme point>` |

The inputs and outputs of the unit are the flows on its lines, in
`Results/<simulation_name>_x.csv`.
