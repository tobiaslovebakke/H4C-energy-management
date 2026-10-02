# Time series data

This folder contains the time series of the network as CSV files, e.g. the
generation profile of a PV park, electricity prices or a heat demand. The JSON
files in `process_data/` refer to these files by their name, e.g.
`"output": "pv_profile.csv"`.

The following fields accept a time series:

| Component | Fields |
|---|---|
| Source | `output`, `price` |
| Demand | `demand`, `price`, `flex_factor` |
| Storage | `a_loss`, `b_loss` |

## File format

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

The model checks the number of columns when it reads a file and stops with an
error message if it does not match the number of scenarios.

See the time-series section of the main README for more information.
