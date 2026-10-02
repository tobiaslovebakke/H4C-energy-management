# Lines

A line is a directed connection between two nodes of the network that transports
one carrier. Lines are the only way in which components interact: a source, unit,
storage or demand exchanges a carrier with the rest of the network only through
the lines that start or end at its node.

Each line is described by one JSON file in this folder.

## Required fields

Every line file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"line"` |
| `name` | text | Name of the line, used as column name in the results |
| `from` | whole number | Node where the line starts |
| `to` | whole number | Node where the line ends |
| `carrier` | text | Carrier transported over the line, e.g. `"electricity"` |

A line with only the required fields can transport any amount, without delay:

```json
{
    "module": "line",
    "name": "grid_to_electrolyser",
    "from": 1,
    "to": 2,
    "carrier": "electricity"
}
```

## Optional fields

These fields can be added when needed; otherwise the default is used.

| Field | Type | Default | Description |
|---|---|---|---|
| `max_cap` | number | `1.0e6` (unlimited) | Maximum flow per time step |
| `min_cap` | number | `0` | Minimum flow per time step |
| `lag` | whole number | `0` | Number of time steps between sending and arrival |
| `cost` | number | `0` (free) | Cost per unit of flow sent over the line |
| `distance` | number | `0` | Length of the line; only used for transport routes |
| `tau_transport` | whole number | `1` | Number of time steps a vehicle is occupied by one trip; only used for transport routes |
| `temperature` | number | `0` | Temperature of the carrier; read, but not used by the current model |

Flows, `min_cap` and `max_cap` are amounts of the carrier per time step, in the
units used throughout your network (e.g. MWh per hourly time step).

The same line, limited to 10 units per time step and with a delay of one time step:

```json
{
    "module": "line",
    "name": "grid_to_electrolyser",
    "from": 1,
    "to": 2,
    "carrier": "electricity",
    "max_cap": 10.0,
    "lag": 1
}
```

## Details

**Direction.** A line only transports in one direction, from `from` to `to`. For
a connection that can be used in both directions, create two lines.

**One carrier per line.** If two nodes exchange several carriers, create one line
per carrier.

**Carriers.** The list of carriers in the model is taken from the lines: every
carrier that appears on at least one line exists in the model. The carrier names
used by the other components (e.g. in the inputs and outputs of a unit) must be
spelled exactly as on the lines. Carrier names must not contain an underscore
(`_`), because the model uses it internally to combine carrier names.

**Minimum flow.** `min_cap` is enforced in every time step and every scenario.
A value above zero therefore forces a flow over the line at all times, also when
it is not economical.

**Lag.** With `lag = k`, a flow sent at time step `t` arrives at time step `t + k`.
This can model, for example, a pipeline or a delivery that takes time. Flows sent
before the start of the optimisation horizon are taken from the initial state.
The number of here-and-now time steps (`T_hn` in the main script) must be at
least as large as the largest lag.

**Cost.** With `cost` set, every unit of flow sent over the line costs that amount,
in every time step and scenario, e.g. a transport fee or network tariff. The cost
is counted in the time step in which the flow is sent. It comes on top of other
costs, such as the price of the source the flow comes from.

**Losses.** Lines have no losses: everything that is sent arrives.

**Transport routes.** Every line that starts at the node of a transport unit is a
route of that unit. For such lines:
- `distance` is used for the distance-dependent cost of a trip;
- `tau_transport` is the number of time steps a vehicle is occupied by one trip,
  which limits how many trips the fleet can make at the same time.

For all other lines these two fields have no effect.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. Lines add their flow cost to this objective:

$$
\sum_{w} \pi_w \sum_{t} \sum_{a} \text{cost}_a \cdot x_{a,t,w}
$$

where $\pi_w$ is the probability of scenario $w$ and $x_{a,t,w}$ the flow sent
over line $a$ in time step $t$ of scenario $w$. Lines without a `cost` add
nothing.

The flows on the lines are also the basis of most other terms in the objective,
which are described with the components themselves: the purchase cost of a
source is charged on the flows leaving its node, the revenue of a demand on the
flows arriving at its node, and the operating cost of a unit on the flows leaving
its node. For lines that are transport routes, `distance` and `tau_transport`
enter the trip cost of the transport unit.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_grid_to_electrolyser.json`,
`2_pv_to_electrolyser.json`. The files are read in the order of these numbers,
which determines the index of each line in the model. Files without a number are
read last.

## Results

The flow on every line is written to `Results/<simulation_name>_x.csv`, with one
column per line, named after the `name` field.
