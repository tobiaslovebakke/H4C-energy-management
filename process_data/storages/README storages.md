# Storages

A storage holds a carrier over time, for example a battery for electricity, a
tank for hydrogen or a thermal storage for heat. It is charged by the lines that
end at its node and discharged by the lines that start at its node, with
efficiencies for charging and discharging and with losses over time.

Each storage is described by one JSON file in this folder.

## Required fields

Every storage file must contain these fields:

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"storage"` |
| `name` | text | Name of the storage, used as column name in the results |
| `node` | whole number | Node at which the storage is located |
| `carrier` | text | Carrier that is stored, e.g. `"heat"` |
| `energy_cap` | number | Maximum content of the storage |

A thermal storage at node 6 that can hold up to 100 units of heat:

```json
{
    "module": "storage",
    "name": "heat_storage",
    "node": 6,
    "carrier": "heat",
    "energy_cap": 100.0
}
```

With only the required fields, the storage can be charged and discharged by up to
`energy_cap` per time step, without losses, and starts empty.

## Optional fields

These fields can be added when needed; otherwise the default is used.

| Field | Type | Default | Description |
|---|---|---|---|
| `charge_cap` | number | `energy_cap` | Maximum inflow per time step |
| `discharge_cap` | number | `charge_cap` | Maximum outflow per time step |
| `charge_eff` | number | `1` | Fraction of the inflow that ends up in the storage |
| `discharge_eff` | number | `1` | Outflow per unit of content taken from the storage |
| `a_loss` | number or CSV file | `0` | Proportional part of the loss function: fraction of the content lost per time step (see [Losses](#losses)) |
| `b_loss` | number or CSV file | `0` | Constant part of the loss function, added to the content per time step (see [Losses](#losses)) |
| `initial_level` | number | `0` | Content at the start of the first optimisation |

`a_loss` and `b_loss` can be a number, used for every time step and scenario, or
the name of a CSV file in `time_series_data/` with a value per time step (and,
optionally, per scenario). See the time-series section of the main README for the
format.

The same thermal storage with limited charging and discharging, efficiencies, a
loss of 1 % of its content per time step, and half full at the start:

```json
{
    "module": "storage",
    "name": "heat_storage",
    "node": 6,
    "carrier": "heat",
    "energy_cap": 100.0,
    "charge_cap": 20.0,
    "discharge_cap": 20.0,
    "charge_eff": 0.95,
    "discharge_eff": 0.95,
    "a_loss": 0.01,
    "initial_level": 50.0
}
```

## Details

**Storage balance.** In every time step the content develops as

$$
y_t = y_{t-1} \cdot (1 - a_t) + b_t + \text{charge\_eff} \cdot \text{inflow}_t - \frac{\text{outflow}_t}{\text{discharge\_eff}}
$$

where $y_t$ is the content at the end of time step $t$, $a_t$ and $b_t$ the
values of `a_loss` and `b_loss`, $\text{inflow}_t$ the total flow arriving over
the lines into the node and $\text{outflow}_t$ the total flow sent over the lines
out of the node. The content always lies between 0 and `energy_cap`.

**Capacities.** `charge_cap` limits the inflow before the charging efficiency is
applied; `discharge_cap` limits the outflow delivered to the lines, after the
discharging efficiency.

### Losses

`a_loss` and `b_loss` together describe the losses of the storage as an
**affine function** of its content. The change of the content due to losses in
time step $t$ is

$$
-\,a_t \cdot y_{t-1} \; + \; b_t
$$

- `a_loss` is the proportional part: the fraction of the content that is lost per
  time step. With `a_loss = 0.01`, 1 % of the content is lost in every time step.
- `b_loss` is the constant part, independent of how full the storage is. A
  negative value reduces the content, a positive value increases it.

Combined, they can represent loss functions that depend on a gradient. In a heat
storage, for example, the heat loss is proportional to the difference between the
storage temperature and the ambient temperature. When the storage temperature
increases linearly with the content, this loss is an affine function of the
content: `a_loss` follows from the heat-loss coefficient, and `b_loss` from the
ambient temperature. Because both can be given as a time series, a varying
ambient temperature can be taken into account through `b_loss`.

In most cases, the losses are simply proportional to the content and `b_loss` is
zero. Note that the content cannot become negative: if `b_loss` is negative and
the storage cannot be charged enough to cover it, the problem has no solution.

### Other details

**Connection to the network.** The storage is charged over the lines that end at
its node and discharged over the lines that start at its node. These lines must
carry the storage's `carrier`; the model counts all lines at the node and does not
check the carrier. Give each storage its own node: all lines at a node are
attributed to the component at that node. If a line into the storage has a lag,
the inflow counts when it arrives.

**Charging and discharging at the same time.** The model does not prevent a
storage from charging and discharging in the same time step. With efficiencies
below 1 this wastes energy, so it only happens when that is beneficial, e.g. to
get rid of a surplus.

**Start and end of the horizon.** The content at the start of the first
optimisation is `initial_level`. There is no requirement on the content at the
end of the horizon: the storage may be emptied by then. In a rolling-horizon
simulation, the content is carried over from one iteration to the next.

**Storage numbers.** The position of a storage in this folder (1 for the first
file, 2 for the second, …) is its storage number. Segment units refer to a
storage by this number (`segment_determiner`).

## Contribution to the objective

A storage adds no costs of its own to the objective. Its use affects the
objective indirectly: through the costs of the carrier that is charged (e.g. the
price of the source it comes from, or the `cost` of the lines it is transported
over) and through the energy lost to efficiencies and losses.

## File names and order

Start every file name with a number, e.g. `1_heat_storage.json`,
`2_battery.json`. The files are read in the order of these numbers, which
determines the storage number. Files without a number are read last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_y.csv` | Content of each storage at the end of each time step |

The charging and discharging flows are the flows on the storage's lines, in
`Results/<simulation_name>_x.csv`.
