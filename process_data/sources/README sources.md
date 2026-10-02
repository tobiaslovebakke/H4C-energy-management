# Sources

A source supplies a carrier to the network, for example a PV park or a wind
turbine producing electricity, a grid connection from which electricity can be
bought, or a supplier of gas or water. A source has an availability (how much it
can supply per time step) and a price per unit taken from it. Both can vary over
time and per scenario, which makes sources the main entry point for uncertainty
in the model, e.g. uncertain renewable generation or uncertain market prices.

Each source is described by one JSON file in this folder.

## Required fields

Every source file must contain these fields; sources have no optional fields.

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"source"` |
| `name` | text | Name of the source |
| `node` | whole number | Node at which the source is located |
| `carrier` | text | Carrier that is supplied, e.g. `"electricity"` |
| `output` | number, `"M"` or CSV file | Maximum amount that can be taken per time step |
| `price` | number or CSV file | Price per unit taken from the source |
| `here_and_now` | `true` / `false` | Whether the amount taken in the here-and-now time steps must be the same in all scenarios |

`output` and `price` can be a number, used for every time step and scenario, or
the name of a CSV file in `time_series_data/` with a value per time step and,
optionally, per scenario. See the time-series section of the main README for the
format. `output` can also be `"M"` for a source without a practical limit, e.g. a
large grid connection.

A PV park at node 1, whose generation is given per scenario in a CSV file, and
whose electricity is free:

```json
{
    "module": "source",
    "name": "pv_park",
    "node": 1,
    "carrier": "electricity",
    "output": "pv_profile.csv",
    "price": 0.0,
    "here_and_now": false
}
```

A grid connection at node 2 with practically unlimited supply, whose price
scenarios are given in a CSV file, and on which electricity is bought day-ahead:

```json
{
    "module": "source",
    "name": "grid_day_ahead",
    "node": 2,
    "carrier": "electricity",
    "output": "M",
    "price": "electricity_price.csv",
    "here_and_now": true
}
```

## Details

**Availability.** In every time step and scenario, the total flow over the lines
that start at the source's node is at most `output`. Taking less than `output`
is always possible, e.g. curtailing PV generation.

**Unlimited sources.** With `"output": "M"`, the availability is set to the
constant `M_sources` from the main script (10 000). If your network can take more
than that per time step from a source, increase `M_sources`.

**Here-and-now sources.** With `"here_and_now": true`, the amount taken from the
source in the here-and-now time steps must be the same in all scenarios. This
represents a decision that has to be made before it is known which scenario
occurs, e.g. buying electricity on the day-ahead market. With
`"here_and_now": false`, the amount taken may differ per scenario, e.g. because
it follows the actual generation of a PV park. For a here-and-now source, the
amount taken in a here-and-now time step can therefore not exceed the lowest
availability over all scenarios.

**Connection to the network.** The source delivers its carrier over the lines that
start at its node; these lines must carry the source's `carrier`. Give each source
its own node: all lines at a node are attributed to the component at that node.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A source adds the cost of what is taken from it:

$$
\sum_{w} \pi_w \sum_{t} \text{price}_{t,w} \cdot \text{output}_{t,w}
$$

where $\pi_w$ is the probability of scenario $w$ and $\text{output}_{t,w}$ the
total flow on the lines leaving the source's node in time step $t$.

- The price is charged per unit actually taken, not per unit available.
- A negative price means that taking from the source earns money, e.g. negative
  electricity prices.
- Selling to a market, e.g. feeding electricity back into the grid, is not a
  source but a demand with a price (see the demands folder).

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_pv_park.json`,
`2_grid_day_ahead.json`. The files are read in the order of these numbers, which
determines the index of each source in the model. Files without a number are read
last.

## Results

Sources have no result file of their own. The amounts taken from a source are the
flows on the lines leaving its node, in `Results/<simulation_name>_x.csv`.
