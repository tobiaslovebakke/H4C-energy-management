# Demands

A demand takes a carrier out of the network, for example the heat demand of a
building, the hydrogen demand of a refuelling station, or electricity sold to the
grid. A demand has a required amount per time step and a price per unit
delivered, which is the revenue the network earns by delivering to it. Both can
vary over time and per scenario.

A demand is either **non-flexible**, and must be met in every time step, or
**transferable**, and may be shifted in time within limits.

Each demand is described by one JSON file in this folder.

## Required fields

Every demand file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"demand"` |
| `name` | text | Name of the demand, used as column name in the results |
| `node` | whole number | Node at which the demand is located |
| `carrier` | text | Carrier that is demanded, e.g. `"heat"` |
| `demand` | number or CSV file | Required amount per time step |
| `price` | number or CSV file | Revenue per unit delivered |

`demand` and `price` can be a number, used for every time step and scenario, or
the name of a CSV file in `time_series_data/` with a value per time step and,
optionally, per scenario. See the time-series section of the main README for the
format.

The heat demand of an office at node 10, given as a profile in a CSV file, without
revenue:

```json
{
    "module": "demand",
    "name": "office_heat",
    "node": 10,
    "carrier": "heat",
    "demand": "office_heat_profile.csv",
    "price": 0.0
}
```

With only the required fields, the demand is non-flexible and must be met
exactly in every time step and scenario.

## Optional fields

These fields can be added when needed; otherwise the default is used.

| Field | Type | Default | Description |
|---|---|---|---|
| `fulfill_exactly` | `true` / `false` | `true` | `true`: the delivery must equal the demand; `false`: more may be delivered (see below) |
| `flexibility` | text | `"non_flexible"` | `"non_flexible"` or `"transferable"` |
| `flex_factor` | number or CSV file | `0` | Transferable demands only: maximum shift per time step, as a fraction of the demand |
| `flex_interval` | whole number | `6` | Transferable demands only: number of time steps within which shifts must cancel out |

Electricity sold to the grid at node 11 at a scenario-dependent price. The demand
is 0, so nothing has to be delivered, but anything that is delivered earns the
price:

```json
{
    "module": "demand",
    "name": "grid_export",
    "node": 11,
    "carrier": "electricity",
    "demand": 0.0,
    "price": "electricity_price.csv",
    "fulfill_exactly": false
}
```

A hydrogen demand at node 12 of which up to 20 % per time step may be shifted,
provided the shifts cancel out within every 4 time steps:

```json
{
    "module": "demand",
    "name": "hydrogen_station",
    "node": 12,
    "carrier": "hydrogen",
    "demand": "hydrogen_demand.csv",
    "price": 5.0,
    "flexibility": "transferable",
    "flex_factor": 0.2,
    "flex_interval": 4
}
```

## Details

**Delivery.** The delivery to a demand in a time step is the total flow arriving
over the lines that end at its node. If such a line has a lag, its flow counts
when it arrives.

**Exact or minimum delivery.**
- With `"fulfill_exactly": true` (default), the delivery must equal the demand in
  every time step and scenario.
- With `"fulfill_exactly": false`, the demand is a minimum: at least the demand
  must be delivered, and at most the constant `M_demand` from the main script
  (500). This is the usual setting for selling to a market, with a demand of 0.
  If a demand can receive more than `M_demand` per time step, increase `M_demand`.

**Transferable demands.** With `"flexibility": "transferable"`, the demand may be
shifted in time:
- In every time step, the demand can be increased or decreased by at most
  `flex_factor` × demand. With `flex_factor = 0.2` and a demand of 10, between 8
  and 12 can be delivered.
- Within every window of `flex_interval` consecutive time steps, the increases and
  decreases must cancel out, so the total amount delivered over such a window
  equals the total demand. Demand is thus moved in time, not reduced.
- Shifts in the previous horizon are taken into account for the windows at the
  start of the horizon.

`flex_factor` can also be a CSV file, to allow different flexibility per time
step or scenario.

**Connection to the network.** The demand receives its carrier over the lines that
end at its node; these lines must carry the demand's `carrier`. Give each demand
its own node: all lines at a node are attributed to the component at that node.

**Feasibility.** A non-flexible demand must be met in every time step and
scenario. If the network cannot deliver enough in some scenario, the problem has
no solution. Check this first when the model reports infeasibility.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A demand adds its revenue, with a minus sign:

$$
-\sum_{w} \pi_w \sum_{t} \text{price}_{t,w} \cdot \text{delivery}_{t,w}
$$

where $\pi_w$ is the probability of scenario $w$ and $\text{delivery}_{t,w}$ the
total flow on the lines into the demand's node.

- With a price of 0, the demand has no influence on the objective; it only has to
  be met.
- With a positive price, every unit delivered earns money. Combined with
  `"fulfill_exactly": false`, the model delivers more than the demand whenever
  that is profitable, e.g. selling electricity when prices are high.
- The revenue is counted in the time step in which the flow is sent. For lines
  with a lag, this is `lag` time steps before the delivery counts towards the
  demand.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_office_heat.json`,
`2_grid_export.json`. The files are read in the order of these numbers, which
determines the index of each demand in the model. Files without a number are read
last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_v_up.csv` | Transferable demands: increase of the demand in each time step |
| `Results/<simulation_name>_v_down.csv` | Transferable demands: decrease of the demand in each time step |

The deliveries are the flows on the lines into the demand's node, in
`Results/<simulation_name>_x.csv`.
