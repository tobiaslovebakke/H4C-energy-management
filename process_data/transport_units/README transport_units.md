# Transport units

A transport unit is a fleet of vehicles that ships a carrier in discrete trips,
for example a fleet of trucks that delivers hydrogen to several customers. Each
trip has a cost that depends on the distance of the route and on how long the
vehicle is occupied, but not on how much is loaded. The number of vehicles limits
how many trips can be under way at the same time.

Each transport unit is described by one JSON file in this folder.

## How a transport unit is set up

A transport unit is located at a node, its **depot**:

- **Lines into the depot** bring the carrier that is to be shipped, e.g. from a
  production unit or a storage.
- **Lines out of the depot are the routes** of the transport unit. Every line that
  starts at the depot is a route to the node at its end. For route lines, three
  line fields are relevant:
  - `distance`: length of the route, used for the trip cost;
  - `tau_transport`: number of time steps a vehicle is occupied by one trip on
    this route, including the return trip;
  - `lag`: number of time steps until the load arrives at the destination.

The depot has no storage: everything that arrives at the depot in a time step
must leave on a route in the same time step. If a line into the depot has a lag,
its flow counts when it arrives. To collect the carrier before shipping,
place a storage in front of the depot.

## Required fields

Every transport unit file must contain these fields; transport units have no
optional fields.

| Field | Type | Description |
|---|---|---|
| `module` | text | Must be `"transport_unit"` |
| `name` | text | Name of the transport unit, used as column name in the results |
| `node` | whole number | Node of the depot |
| `carrier` | text | Carrier that is transported, e.g. `"hydrogen"` |
| `cost_fixed` | number | Fixed cost per trip |
| `cost_distance` | number | Cost per unit of route distance, per trip, e.g. fuel cost |
| `cost_time` | number | Cost per time step that a vehicle is occupied, per trip, e.g. driver salary |
| `min_output` | number | Minimum load of one trip |
| `max_output` | number | Maximum load of one trip |
| `fleet_cap` | whole number | Number of vehicles: maximum number of trips under way at the same time |

A fleet of two hydrogen trucks with its depot at node 7, each carrying between
0.5 and 5 units per trip:

```json
{
    "module": "transport_unit",
    "name": "hydrogen_trucks",
    "node": 7,
    "carrier": "hydrogen",
    "cost_fixed": 50.0,
    "cost_distance": 1.2,
    "cost_time": 10.0,
    "min_output": 0.5,
    "max_output": 5.0,
    "fleet_cap": 2
}
```

Two routes, from the depot to customers at nodes 8 and 9, are defined as lines
in the lines folder:

```json
{
    "module": "line",
    "name": "trucks_to_customer_A",
    "from": 7,
    "to": 8,
    "carrier": "hydrogen",
    "distance": 30.0,
    "tau_transport": 2,
    "lag": 1
}
```

```json
{
    "module": "line",
    "name": "trucks_to_customer_B",
    "from": 7,
    "to": 9,
    "carrier": "hydrogen",
    "distance": 60.0,
    "tau_transport": 4,
    "lag": 2
}
```

A trip to customer A costs 50 + 1.2 × 30 + 10 × 2 = 106, takes one time step to
deliver and keeps a truck busy for two time steps.

## Details

**Trips.** In every time step, at most one trip can depart on each route. A trip
that departs carries between `min_output` and `max_output`; without a trip, the
route carries nothing.

**Fleet capacity.** A trip that departs in time step `t` occupies a vehicle in
time steps `t`, `t + 1`, …, `t + tau_transport − 1`. In every time step, the
number of occupied vehicles of a transport unit cannot exceed `fleet_cap`. Trips
that departed before the start of the optimisation horizon are taken from the
initial state (by default, no trips are under way).

**Delivery time and occupation time.** `lag` and `tau_transport` are separate:
`lag` is when the load arrives, `tau_transport` how long the vehicle is busy. As
a vehicle usually has to return to the depot, `tau_transport` is normally at
least as large as `lag`.

**Here-and-now decisions.** In the here-and-now time steps, which trips depart is
the same in all scenarios. The amount loaded on a trip may still differ per
scenario, within `min_output` and `max_output`.

**Carrier.** Each transport unit is dedicated to one carrier, given by `carrier`.
The lines into the depot and the route lines must carry this carrier; to transport
several carriers, use one transport unit (with its own depot) per carrier. The
model takes the transported carrier from the lines and does not check that it
matches `carrier`.

## Contribution to the objective

The model minimises the expected cost minus the expected revenue over all
scenarios. A transport unit adds the cost of its trips:

$$
\sum_{w} \pi_w \sum_{t} \sum_{r} \text{trip}_{r,t,w} \cdot \big( \text{cost\_fixed} + \text{cost\_distance} \cdot \text{distance}_r + \text{cost\_time} \cdot \text{tau\_transport}_r \big)
$$

where $\pi_w$ is the probability of scenario $w$, $\text{trip}_{r,t,w}$ equals 1
if a trip departs on route $r$ in time step $t$, and $\text{distance}_r$ and
$\text{tau\_transport}_r$ are the fields of the route line.

The cost of one trip consists of three parts:

- **Fixed cost** (`cost_fixed`): charged for every trip, e.g. loading and
  handling.
- **Distance-dependent cost** (`cost_distance` × route distance): grows with the
  length of the route, and can be used to model e.g. fuel costs.
- **Time-dependent cost** (`cost_time` × `tau_transport`): grows with the time a
  vehicle is occupied, and can be used to model e.g. the salary of the driver.

The trip cost does not depend on the load: a full and a nearly empty trip cost
the same. A cost per unit of transported carrier can be added with the `cost`
field of the route lines (see the lines folder); it comes on top of the trip
cost.

The here-and-now objective reported in the results (`objective_hn`) contains the
same terms, restricted to the here-and-now time steps.

## File names and order

Start every file name with a number, e.g. `1_hydrogen_trucks.json`,
`2_tankers.json`. The files are read in the order of these numbers, which
determines the index of each transport unit in the model. Files without a number
are read last.

## Results

| File | Content |
|---|---|
| `Results/<simulation_name>_z_transport.csv` | 1 if a trip departs; columns are named `<name>_<route number>` |

The route numbers follow the order of the route lines in the lines folder: route 1
is the first line (by file number) that starts at the depot, route 2 the second,
and so on. The loads of the trips are the flows on the route lines, in
`Results/<simulation_name>_x.csv`.
