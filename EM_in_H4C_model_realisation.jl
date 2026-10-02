#Generic function that take a result a vector and locks the values of realisation
function lock_variables!(vars_dict, values_dict, idxs_dict)  
    for (var_sym, idxs) in idxs_dict   # loop only over variables with idxs
        var_ref = vars_dict[var_sym]
        values  = values_dict[var_sym]
        for I in idxs
            #print(var_sym)
            if is_binary(var_ref[I...]) || is_integer(var_ref[I...])
                fix(var_ref[I...], round(values[I...]); force=true)
            else
                fix(var_ref[I...], round(values[I...], digits=6); force=true)
            end
            #println(values[I...])
        end
    end
end



function h4c_realisation(
    lines::Vector{<:Line},
    sources::Vector{<:Source},
    units::Vector{<:Unit},
    cg_units::Vector{<:CG_Unit},
    transport_units::Vector{<:Transport_Unit},
    multi_units::Vector{<:Multi_Unit},
    segment_units::Vector{<:Segment_Unit},
    storages::Vector{<:Storage},
    demands::Vector{<:Demand},
    demands_nf::Vector{<:Demand},
    demands_transferable::Vector{<:Demand},
    ini_vec::Dict,
    probs::Vector{<:Any},
    first_stage_values,
    idxs_first_stage,
    T, T_hn;
    optimizer=Gurobi.Optimizer,
    threads=0,
    nodes=Inf,
    time_limit::Union{Nothing, Real} = nothing)

    U                  = size(units,1)
    U_CG               = length(cg_units)
    U_trans            = length(transport_units)
    U_multi            = length(multi_units)
    U_segment = length(segment_units)
    A                  = size(lines,1)
    E                  = size(sources,1)
    S                  = size(storages,1)
    D                  = size(demands,1)
    D_nf               = length(demands_nf)
    D_transfer         = length(demands_transferable)
    F                  = size(carriers,1)
    pi = probs
    if !isempty(cg_units)
        G    = maximum(size.(extreme_cgs, 2))
    else
        G = 0
    end

    if !isempty(multi_units)
        state_vec = getfield.(multi_units, :states)
        Q    = maximum(length.(state_vec))
    else
        Q = 0
    end

    if !isempty(segment_units)
        I = maximum(getfield.(segment_units, :num_segments))
    else
        I = 0
    end


    if !isempty(transport_units)
        num_routes = []
        tau_routes = []
        for u in transport_units
            sum_routes = sum(1 for a in 1:A if lines[a].from == u.node)
            push!(num_routes,sum_routes)
        end
        R = maximum(num_routes)
        route_lines = zeros(Int, U_trans,R)
        tau_routes = zeros(Int, U_trans,R)
        for u in 1:U_trans
            r = 1
            for a in 1:A
                if lines[a].from == transport_units[u].node
                    tau_routes[u,r] = lines[a].tau_transport
                    route_lines[u,r] = a
                    r = r + 1
                end
            end
        end
        tau_transports = []
        for a in 1:A
            push!(tau_transports,lines[a].tau_transport)
        end
        tau_max = maximum(tau_transports)
    else    
        R = 0
        tau_max = 0
        tau_routes = zeros(Int,0,0)
        route_lines = zeros(Int,0,0)
    end

    tau_routes = [Int(x) for x in tau_routes]

    # create_model and apply_time_limit! are defined in EM_in_H4C_model_stochastic.jl
    h4c_real = create_model(optimizer, threads, nodes, "realisation_$(simulation_name)")

    @variable(h4c_real, x[1:A, 1:T, 1:W] >= 0)           # Flow on each arc


    @variable(h4c_real, y[1:S, 1:T, 1:W] >= 0)           # Storage energy content


    @variable(h4c_real, z[1:U, 1:T, 1:W], Bin)           # On variable of each production unit
    @variable(h4c_real, z_start[1:U, 1:T, 1:W], Bin)     # Start variable of each production unit
    @variable(h4c_real, z_stop[1:U, 1:T, 1:W], Bin)      # Stop variable of each production unit


    for u in 1:U
        if units[u].start_stop_cost == 0 && units[u].start_up_time==0 && all(units[u].min_input .== 0) && all(units[u].min_output .== 0)
            fix.(z[u,:,:], 1; force=true)
            # t=1 is left free: its z_start/z_stop value depends on ini_vec[:z][u,end] via
            # unit_start_stop_ini and can be 1 if the unit was off at the end of the prior horizon.
            fix.(z_start[u,2:T,:], 0; force=true)
            fix.(z_stop[u,2:T,:], 0; force=true)
        end
    end

    @variable(h4c_real, 0 <= alpha[1:U_CG, 1:G, 1:T, 1:W] <= 1)
    @variable(h4c_real,      z_cg[1:U_CG, 1:T, 1:W],       Bin)
    @variable(h4c_real,      z_cg_start[1:U_CG, 1:T, 1:W], Bin)
    @variable(h4c_real,      z_cg_stop[1:U_CG, 1:T, 1:W],  Bin)

    @variable(h4c_real, x_multi_main[1:U_multi, 1:Q, 1:T, 1:W] >= 0)
    @variable(h4c_real, z_multi_on[1:U_multi, 1:T, 1:W], Bin)
    @variable(h4c_real, z_multi_h_start[1:U_multi, 1:T, 1:W], Bin)    #Hot start (from standby to on)
    @variable(h4c_real, z_multi_c_start[1:U_multi, 1:T, 1:W], Bin)    #Cold start (from off to on)
    @variable(h4c_real, z_multi_h_stop[1:U_multi, 1:T, 1:W], Bin)     #Hot stop (from on to standby)
    @variable(h4c_real, z_multi_c_stop[1:U_multi, 1:T, 1:W], Bin)     #Cold stop (from on to off)
    @variable(h4c_real, z_multi_state[1:U_multi, 1:Q, 1:T, 1:W], Bin) #Binary variable keeping track which state is activated


    @variable(h4c_real, x_segment_in[1:U_segment, 1:I, 1:F, 1:T, 1:W] >= 0)
    @variable(h4c_real, z_segment_state[1:U_segment, 1:I, 1:T, 1:W], Bin) #Binary variable keeping track which state is activated
    @variable(h4c_real, z_segment_on[1:U_segment, 1:T, 1:W], Bin)
    @variable(h4c_real, z_segment_start[1:U_segment, 1:T, 1:W], Bin)     # Start variable of each production unit
    @variable(h4c_real, z_segment_stop[1:U_segment, 1:T, 1:W], Bin)      # Stop variable of each production unit

    @variable(h4c_real, z_transport[1:U_trans, 1:R, 1:T, 1:W], Bin)

    @variable(h4c_real, v_up[1:D_transfer, 1:T, 1:W]   >= 0)
    @variable(h4c_real, v_down[1:D_transfer, 1:T, 1:W] >= 0)

    vars_det = Dict(
    :x               => x,
    :y               => y,
    :z               => z,
    :z_start         => z_start,
    :z_stop          => z_stop,
    :alpha           => alpha,
    :z_cg            => z_cg,
    :z_cg_start      => z_cg_start,
    :z_cg_stop       => z_cg_stop,
    :z_transport     => z_transport,
    :v_up            => v_up,
    :v_down          => v_down,
    :x_multi_main    => x_multi_main,
    :z_multi_on      => z_multi_on,
    :z_multi_h_start => z_multi_h_start,
    :z_multi_c_start => z_multi_c_start,
    :z_multi_h_stop  => z_multi_h_stop,
    :z_multi_c_stop  => z_multi_c_stop,
    :z_multi_state   => z_multi_state,
    :z_segment_on => z_segment_on
    )


    @objective(h4c_real, Min, sum(pi[w]*(sum(lines[a].cost*x[a,t,w] for a in 1:A) +
                        sum(sources[e].price[t,w]*x[a,t,w] for e in 1:E, a in 1:A if lines[a].from == sources[e].node) +
                        sum(units[u].start_stop_cost*z_stop[u,t,w] for u in 1:U)+
                        sum(units[u].cost_operating[f]*x[a,t,w] for u in 1:U, f in 1:F, a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) +
                        sum(cg_units[u].start_stop_cost*z_cg_stop[u,t,w] for u in 1:U_CG) +
                        sum(cg_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_CG, f in 1:F, a in 1:A if lines[a].from == cg_units[u].node && lines[a].carrier == carriers[f]) +
                        sum(z_transport[u,r,t,w]*(transport_units[u].cost_fixed + transport_units[u].cost_distance*lines[route_lines[u,r]].distance + transport_units[u].cost_time*tau_routes[u,r]) for u in 1:U_trans, r in 1:R if route_lines[u,r] > 0) -
                        sum(demands[d].price[t,w]*x[a,t,w] for d in 1:D, a in 1:A if lines[a].to == demands[d].node) +
                        sum(multi_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_multi, f in 1:F, a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f]) +
                        sum(z_multi_c_stop[u,t,w]*multi_units[u].start_stop_cost[2] for u in 1:U_multi) + 
                        sum(z_multi_h_stop[u,t,w]*multi_units[u].start_stop_cost[1] for u in 1:U_multi) +
                        sum(segment_units[u].start_stop_cost*z_segment_stop[u,t,w] for u in 1:U_segment) +
                        sum(segment_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_segment, f in 1:F, a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f])) for t in 1:T, w in 1:W))

    @constraint(h4c_real, x_max_in[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                        sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                        <= z[u,t,w]* units[u].max_input[f])
    @constraint(h4c_real, x_min_in[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                        sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                        >= z[u,t,w]* units[u].min_input[f])

    @constraint(h4c_real, x_max_out[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) 
                                                            <= z[u,t,w]* units[u].max_output[f])
    @constraint(h4c_real, x_min_out[u=1:U, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) 
                                                            >= z[u,t,w]* units[u].min_output[f])


    @constraint(h4c_real, unit_start_stop[u=1:U, t=2:T, w=1:W], z_start[u,t,w] - z_stop[u,t,w] == z[u,t,w]- z[u,t-1,w])
    @constraint(h4c_real, unit_start_stop_ini[u=1:U, w=1:W],    z_start[u,1,w] - z_stop[u,1,w] == z[u,1,w]- ini_vec[:z][u,end])

    @constraint(h4c_real, unit_ss_sum[u=1:U, t=1:T, w=1:W],     z_start[u,t,w] + z_stop[u,t,w] <= 1)

    @constraint(h4c_real, unit_ramp_up[u=1:U, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_up[f] + z_start[u,t,w]*units[u].min_output[f])
    @constraint(h4c_real, unit_ramp_down[u=1:U, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_down[f] + z_stop[u,t,w]*units[u].min_output[f])

    # Ramping limits in time step 1, relative to the last output of the previous horizon (ini_vec)
    @constraint(h4c_real, unit_ramp_up_ini[u=1:U, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_up[f] + z_start[u,t,w]*units[u].min_output[f])
    @constraint(h4c_real, unit_ramp_down_ini[u=1:U, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == units[u].node  && lines[a].carrier == carriers[f]) <= units[u].ramp_down[f] + z_stop[u,t,w]*units[u].min_output[f])
    
    # Unit min down/up time constraints
    @constraint(h4c_real, unit_min_down_t[u=1:U, t=1:T, w=1:W],
        sum(z[u,t1,w] for t1 in t:min(t+units[u].min_down_time-1, T))
        <= min(units[u].min_down_time, T-t+1) * (1 - z_stop[u,t,w]))

    @constraint(h4c_real, unit_min_up_t[u=1:U, t=1:T, w=1:W],
        sum(z[u,t1,w] for t1 in t:min(t+units[u].min_up_time-1, T))
        >= min(units[u].min_up_time, T-t+1) * z_start[u,t,w])

    # Unit carry-over from previous day
    @constraint(h4c_real, unit_min_down_t_ini[u=1:U, t=1:T, w=1:W; t <= units[u].min_down_time-1],
        sum(z[u,t1,w] for t1 in 1:t)
        <= t * (1 - ini_vec[:z_stop][u, end-units[u].min_down_time+1+t]))

    @constraint(h4c_real, unit_min_up_t_ini[u=1:U, t=1:T, w=1:W; t <= units[u].min_up_time-1],
        sum(z[u,t1,w] for t1 in 1:t)
        >= t * ini_vec[:z_start][u, end-units[u].min_up_time+1+t])
    
    @constraint(h4c_real, fleet_capacity[u=1:U_trans, t=1:T, w=1:W],  sum(z_transport[u,r,t1,w] for r in 1:R, t1 in maximum([1,t-tau_routes[u,r]+1]):t if route_lines[u,r] > 0) + 
                                                                 sum(ini_vec[:z_transport][u,r,end+t1] for r in 1:R, t1 in t-tau_routes[u,r]+1:0 if route_lines[u,r] > 0 && (t1-tau_routes[u,r]+1) <= 0) <= transport_units[u].fleet_cap)


    # Only the routes that exist (route_lines[u,r] > 0) are used: units with fewer routes than R
    # have empty route slots, in which no trips can take place.
    @constraint(h4c_real, min_transport[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] > 0], x[route_lines[u,r],t,w] >= z_transport[u,r,t,w]*transport_units[u].min_output)
    @constraint(h4c_real, max_transport[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] > 0], x[route_lines[u,r],t,w] <= z_transport[u,r,t,w]*transport_units[u].max_output)
    @constraint(h4c_real, no_trip_empty_route[u=1:U_trans, r=1:R, t=1:T, w=1:W; route_lines[u,r] == 0], z_transport[u,r,t,w] == 0)
    # Everything that arrives at the depot (taking the line lags into account) leaves on a route
    @constraint(h4c_real, transport_balance[u=1:U_trans, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == transport_units[u].node && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == transport_units[u].node && lines[a].lag == lags[l] && t-lags[l] <= 0)
                                                                   == sum(x[route_lines[u,r],t,w] for r in 1:R if route_lines[u,r] > 0))



    @constraint(h4c_real, y_update[s = 1:S, t=2:T, w=1:W], y[s,t,w] == y[s,t-1,w]*(1-storages[s].a_loss[t,w]) + storages[s].b_loss[t,w] + 
                                                                sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] >= 1)*storages[s].charge_eff     + 
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] <= 0)*storages[s].charge_eff - 
                                                                sum(x[a,t,w] for a in 1:A if lines[a].from == storages[s].node)/storages[s].discharge_eff)




    @constraint(h4c_real, y_update_ini[s = 1:S, w=1:W],    y[s,1,w] == ini_vec[:y][s,end]*(1-storages[s].a_loss[1,w]) + storages[s].b_loss[1,w] + 
                                                                sum(x[a,1-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && 1-lags[l] >= 1)*storages[s].charge_eff     + 
                                                                sum(ini_vec[:x][a,end+1-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && 1-lags[l] <= 0)*storages[s].charge_eff -  
                                                                sum(x[a,1,w] for a in 1:A if lines[a].from == storages[s].node)/storages[s].discharge_eff)


    @constraint(h4c_real, unit_balance[u=1:U, f=1:F, f1=1:F, t=1:T, w=1:W], sum(units[u].conv_matrix[f,f1]*x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                    sum(units[u].conv_matrix[f,f1]*ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0)  -
                                                                    sum(x[a,t,w] for a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f1] && units[u].conv_matrix[f,f1] != 0)  == 0)



    
                                                            
    @constraint(h4c_real, source_balance[e=1:E, t=1:T, w=1:W],         sum(x[a,t,w] for a in 1:A if lines[a].from    == sources[e].node) <= sources[e].output[t,w])
    if W > 1
        @constraint(h4c_real, source_here_and_now[e=1:E, t=1:T_hn, w=2:W], sum(x[a,t,w-1] for a in 1:A if lines[a].from  == sources[e].node)*sources[e].here_and_now
                                                                        == sum(x[a,t,w] for a in 1:A if lines[a].from    == sources[e].node)*sources[e].here_and_now) #Source non-anticipativity
    end
    #NEW FLOW-LAG CONSTRAINTS
    @constraint(h4c_real, demand_lower[d=1:D_nf, t=1:T, w=1:W],    sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     + 
                                                              sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) >= demands_nf[d].demand[t,w])
    @constraint(h4c_real, demand_upper[d=1:D_nf, t=1:T, w=1:W],    sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                              sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_nf[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= demands_nf[d].fulfill_exactly*demands_nf[d].demand[t,w] + 
                                                                                                                                                                                                    (1-demands_nf[d].fulfill_exactly) * M_demand)


    @constraint(h4c_real, demand_transfer_lower[d=1:D_transfer, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     + 
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) >= demands_transferable[d].demand[t,w] + v_up[d,t,w] - v_down[d,t,w])
    @constraint(h4c_real, demand_transfer_upper[d=1:D_transfer, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == demands_transferable[d].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= demands_transferable[d].fulfill_exactly*demands_transferable[d].demand[t,w] + v_up[d,t,w] - v_down[d,t,w] + 
                                                                                                                                                                                                                (1-demands_transferable[d].fulfill_exactly) * M_demand)

    @constraint(h4c_real, demand_transfer_up[d=1:D_transfer, t=1:T, w=1:W],   v_up[d,t,w]   <= demands_transferable[d].flexibility["flex_factor"][t,w] * demands_transferable[d].demand[t,w])
    @constraint(h4c_real, demand_transfer_down[d=1:D_transfer, t=1:T, w=1:W], v_down[d,t,w] <= demands_transferable[d].flexibility["flex_factor"][t,w] * demands_transferable[d].demand[t,w])

    @constraint(h4c_real, demand_transfer_sum[d=1:D_transfer, t=1:T, w=1:W],  sum(v_up[d,t1,w]   for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1>=1) + sum(v_up_ini[d,end+t1]   for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1<=0) 
                                                                    == sum(v_down[d,t1,w] for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1>=1) + sum(v_down_ini[d,end+t1] for t1 in t-demands_transferable[d].flexibility["flex_interval"]+1:t if t1<=0))


                                                                                                                                                                        

    @constraint(h4c_real, y_max[s = 1:S, t=1:T, w=1:W],              y[s,t,w]                                                         <= storages[s].energy_cap)
    @constraint(h4c_real, y_charge_max[s = 1:S, t=1:T, w=1:W],       sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == storages[s].node && lines[a].lag == lags[l] && t-lags[l] >= 1)     +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to   == storages[s].node && lines[a].lag == lags[l] && t-lags[l] <= 0) <= storages[s].charge_cap)

    # Discharge: the flow sent out of the storage in time step t (lags only affect arrival)
    @constraint(h4c_real, y_discharge_max[s = 1:S, t=1:T, w=1:W],    sum(x[a,t,w] for a in 1:A if lines[a].from == storages[s].node) <= storages[s].discharge_cap)


    @constraint(h4c_real, cg_inflow[u=1:U_CG, f=1:F, t=1:T, w=1:W],  sum(alpha[u,g,t,w]*cg_units[u].fuel[f,g] for g in 1:G) == 
                                                                sum(x[a,t-lags[l],w] for  a in 1:A, l in 1:L+1 if lines[a].to == cg_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) +
                                                                sum(ini_vec[:x][a,end+t-lags[l]] for  a in 1:A, l in 1:L+1 if lines[a].to == cg_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0))

    @constraint(h4c_real, alpha_out[u=1:U_CG, f=1:F, t=1:T, w=1:W],  sum(alpha[u,g,t,w]*cg_units[u].extreme[f,g] for g in 1:G)
                                                                ==  sum(x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]))

    @constraint(h4c_real, alpha_on[u=1:U_CG, t=1:T, w=1:W],          sum(alpha[u,g,t,w] for g in 1:G) == z_cg[u,t,w])


    @constraint(h4c_real, unit_cg_start_stop[u=1:U_CG, t=2:T, w=1:W], z_cg_start[u,t,w] - z_cg_stop[u,t,w] == z_cg[u,t,w]- z_cg[u,t-1,w])
    @constraint(h4c_real, unit_cg_start_stop_ini[u=1:U_CG, w=1:W],    z_cg_start[u,1,w] - z_cg_stop[u,1,w] == z_cg[u,1,w]- ini_vec[:z_cg][u,end])

    @constraint(h4c_real, unit_cg_ss_sum[u=1:U_CG, t=1:T, w=1:W],     z_cg_start[u,t,w] + z_cg_stop[u,t,w] <= 1)

    @constraint(h4c_real, unit_cg_ramp_up[u=1:U_CG, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_up[f]   + z_cg_start[u,t,w]*minimum(cg_units[u].extreme[f,:]))
    @constraint(h4c_real, unit_cg_ramp_down[u=1:U_CG, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_down[f] + z_cg_stop[u,t,w]*minimum(cg_units[u].extreme[f,:]))

    # Ramping limits in time step 1, relative to the last output of the previous horizon (ini_vec)
    @constraint(h4c_real, unit_cg_ramp_up_ini[u=1:U_CG, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_up[f]   + z_cg_start[u,t,w]*minimum(cg_units[u].extreme[f,:]))
    @constraint(h4c_real, unit_cg_ramp_down_ini[u=1:U_CG, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == cg_units[u].node  && lines[a].carrier == carriers[f]) <= cg_units[u].ramp_down[f] + z_cg_stop[u,t,w]*minimum(cg_units[u].extreme[f,:]))

    # CG unit min down/up time constraints
    @constraint(h4c_real, cg_min_down_t[u=1:U_CG, t=1:T, w=1:W],
        sum(z_cg[u,t1,w] for t1 in t:min(t+cg_units[u].min_down_time-1, T))
        <= min(cg_units[u].min_down_time, T-t+1) * (1 - z_cg_stop[u,t,w]))

    @constraint(h4c_real, cg_min_up_t[u=1:U_CG, t=1:T, w=1:W],
        sum(z_cg[u,t1,w] for t1 in t:min(t+cg_units[u].min_up_time-1, T))
        >= min(cg_units[u].min_up_time, T-t+1) * z_cg_start[u,t,w])

    # CG carry-over from previous day
    @constraint(h4c_real, cg_min_down_t_ini[u=1:U_CG, t=1:T, w=1:W; t <= cg_units[u].min_down_time-1],
        sum(z_cg[u,t1,w] for t1 in 1:t)
        <= t * (1 - ini_vec[:z_cg_stop][u, end-cg_units[u].min_down_time+1+t]))

    @constraint(h4c_real, cg_min_up_t_ini[u=1:U_CG, t=1:T, w=1:W; t <= cg_units[u].min_up_time-1],
        sum(z_cg[u,t1,w] for t1 in 1:t)
        >= t * ini_vec[:z_cg_start][u, end-cg_units[u].min_up_time+1+t])


    @constraint(h4c_real, x_multi_low_in_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W],  sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                                   >= sum(multi_units[u].min_input[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    @constraint(h4c_real, x_multi_high_in_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) 
                                                                   <= sum(multi_units[u].max_input[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    @constraint(h4c_real, x_multi_low_out_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W],  sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f])
                                                                   >= sum(multi_units[u].min_output[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))
    @constraint(h4c_real, x_multi_high_out_cap[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f])
                                                                   <= sum(multi_units[u].max_output[q,f]*z_multi_state[u,q,t,w] for q in 1:Q))

    


    @constraint(h4c_real, multi_unit_balance_in[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == multi_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0) == 
                                                                   sum(x_multi_main[u,q,t,w]*multi_units[u].a_input[q,f] + z_multi_state[u,q,t,w]*multi_units[u].b_input[q,f] for q in 1:Q))

    @constraint(h4c_real, multi_unit_balance_out[u=1:U_multi, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f]) == 
                                                                   sum(x_multi_main[u,q,t,w]*multi_units[u].a_output[q,f] + z_multi_state[u,q,t,w]*multi_units[u].b_output[q,f] for q in 1:Q))

    
    @constraint(h4c_real, multi_unit_main_low[u=1:U_multi, q=1:Q, t=1:T, w=1:W],  x_multi_main[u,q,t,w] >= sum(multi_units[u].min_output[q,f]*z_multi_state[u,q,t,w] for f in 1:F if multi_units[u].main_output[f]==1))
    @constraint(h4c_real, multi_unit_main_high[u=1:U_multi, q=1:Q, t=1:T, w=1:W], x_multi_main[u,q,t,w] <= sum(multi_units[u].max_output[q,f]*z_multi_state[u,q,t,w] for f in 1:F if multi_units[u].main_output[f]==1))
                                                                             
    @constraint(h4c_real, multi_unit_ss[u=1:U_multi, t=2:T, w=1:W],             z_multi_h_start[u,t,w] + z_multi_c_start[u,t,w] -  z_multi_h_stop[u,t,w] - z_multi_c_stop[u,t,w] == z_multi_on[u,t,w] - z_multi_on[u,t-1,w])
    @constraint(h4c_real, multi_unit_hot_ss[u=1:U_multi, t=2:T, w=1:W],         z_multi_h_stop[u,t,w]  - z_multi_h_start[u,t,w] == sum(z_multi_state[u,q,t,w] - z_multi_state[u,q,t-1,w] for q in 1:Q if multi_units[u].states[q]=="standby"))
    @constraint(h4c_real, multi_unit_cold_ss[u=1:U_multi, t=2:T, w=1:W],        z_multi_c_stop[u,t,w]  - z_multi_c_start[u,t,w] == sum(z_multi_state[u,q,t,w] - z_multi_state[u,q,t-1,w]  for q in 1:Q if multi_units[u].states[q]=="off"))
    @constraint(h4c_real, multi_unit_off_to_standby[u=1:U_multi, t=2:T, w=1:W], sum(z_multi_state[u,q,t-1,w]  for q in 1:Q if multi_units[u].states[q]=="off") + sum(z_multi_state[u,q,t,w]  for q in 1:Q if multi_units[u].states[q]=="standby") <= 1)


    
    @constraint(h4c_real, multi_unit_ss_ini[u=1:U_multi, w=1:W],                z_multi_h_start[u,1,w] + z_multi_c_start[u,1,w] -  z_multi_h_stop[u,1,w] - z_multi_c_stop[u,1,w] == z_multi_on[u,1,w] - ini_vec[:z_multi_on][u,end])
    @constraint(h4c_real, multi_unit_hot_ss_ini[u=1:U_multi, w=1:W],            z_multi_h_stop[u,1,w]  - z_multi_h_start[u,1,w] == sum(z_multi_state[u,q,1,w] - ini_vec[:z_multi_state][u,q,end] for q in 1:Q if multi_units[u].states[q]=="standby"))
    @constraint(h4c_real, multi_unit_cold_ss_ini[u=1:U_multi, w=1:W],           z_multi_c_stop[u,1,w]  - z_multi_c_start[u,1,w] == sum(z_multi_state[u,q,1,w] - ini_vec[:z_multi_state][u,q,end]  for q in 1:Q if multi_units[u].states[q]=="off"))
    @constraint(h4c_real, multi_unit_off_to_standby_ini[u=1:U_multi, w=1:W],    sum(ini_vec[:z_multi_state][u,q,end]  for q in 1:Q if multi_units[u].states[q]=="off") + sum(z_multi_state[u,q,1,w]  for q in 1:Q if multi_units[u].states[q]=="standby") <= 1)
    
    
    @constraint(h4c_real, multi_unit_ss_sum[u=1:U_multi, t=1:T, w=1:W], z_multi_h_start[u,t,w] + z_multi_c_start[u,t,w] + z_multi_h_stop[u,t,w] + z_multi_c_stop[u,t,w] <= 1)
    

    @constraint(h4c_real, multi_unit_state[u=1:U_multi, t=1:T, w=1:W], sum(z_multi_state[u,q,t,w] for q in 1:Q) == 1)

    @constraint(h4c_real,multi_unit_on_state[u=1:U_multi, t=1:T, w=1:W], sum(z_multi_state[u,q,t,w] for q in 1:Q if multi_units[u].states[q]=="on") == z_multi_on[u,t,w])

        
    @constraint(h4c_real, multi_unit_ramp_up[u=1:U_multi, f=1:F, t=2:T, w=1:W],    sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_up[f]   + (z_multi_h_start[u,t,w]+z_multi_c_start[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    @constraint(h4c_real, multi_unit_ramp_down[u=1:U_multi, f=1:F, t=2:T, w=1:W],  sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_down[f] + (z_multi_h_stop[u,t,w]+z_multi_c_stop[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))


    @constraint(h4c_real, multi_unit_ramp_up_ini[u=1:U_multi, f=1:F, t=1:1, w=1:W],    sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_up[f]   + (z_multi_h_start[u,t,w]+z_multi_c_start[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    @constraint(h4c_real, multi_unit_ramp_down_ini[u=1:U_multi, f=1:F, t=1:1, w=1:W],  sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == multi_units[u].node  && lines[a].carrier == carriers[f]) <= multi_units[u].ramp_down[f] + (z_multi_h_stop[u,t,w]+z_multi_c_stop[u,t,w])*minimum(multi_units[u].min_output[q,f] for q in 1:Q if multi_units[u].states[q] == "on"))
    
    # Multi unit min down/up time constraints
    @constraint(h4c_real, multi_min_down_t[u=1:U_multi, t=1:T, w=1:W],
        sum(z_multi_state[u,q,t1,w] for q in 1:Q, t1 in t:min(t+multi_units[u].min_down_time-1, T) if multi_units[u].states[q]=="off")
        >= min(multi_units[u].min_down_time, T-t+1) * z_multi_c_stop[u,t,w])

    @constraint(h4c_real, multi_min_up_t[u=1:U_multi, t=1:T, w=1:W],
        sum(z_multi_on[u,t1,w] for t1 in t:min(t+multi_units[u].min_up_time-1, T))
        >= min(multi_units[u].min_up_time, T-t+1) * (z_multi_c_start[u,t,w] + z_multi_h_start[u,t,w]))

    # Multi carry-over from previous day
    @constraint(h4c_real, multi_min_down_t_ini[u=1:U_multi, t=1:T, w=1:W; t <= multi_units[u].min_down_time-1],
        sum(z_multi_state[u,q,t1,w] for q in 1:Q, t1 in 1:t if multi_units[u].states[q]=="off")
        >= t * ini_vec[:z_multi_c_stop][u, end-multi_units[u].min_down_time+1+t])

    @constraint(h4c_real, multi_min_up_t_ini[u=1:U_multi, t=1:T, w=1:W; t <= multi_units[u].min_up_time-1],
        sum(z_multi_on[u,t1,w] for t1 in 1:t)
        >= t * (ini_vec[:z_multi_c_start][u, end-multi_units[u].min_up_time+1+t] +
                ini_vec[:z_multi_h_start][u, end-multi_units[u].min_up_time+1+t]))
    
    @constraint(h4c_real, segment_unit_in[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t-lags[l],w] for a in 1:A, l in 1:L+1 if lines[a].to == segment_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] >= 1) + 
                                                                   sum(ini_vec[:x][a,end+t-lags[l]] for a in 1:A, l in 1:L+1 if lines[a].to == segment_units[u].node  && lines[a].carrier == carriers[f] && lines[a].lag == lags[l] && t-lags[l] <= 0)
                                                                   ==sum(x_segment_in[u,i,f,t,w] for i in 1:I))

    @constraint(h4c_real, segment_balance[u=1:U_segment, f=1:F, f1=1:F, t=1:T, w=1:W], sum(x_segment_in[u,i,f,t,w]*segment_units[u].conv_matrix[i,f,f1] for i in 1:I) -
                                                                                  sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f1] && any(segment_units[u].conv_matrix[:,f,f1] .!= 0))  == 0 )

    
    @constraint(h4c_real, segment_unit_in_min[u=1:U_segment,i=1:I, f=1:F, t=1:T, w=1:W], x_segment_in[u,i,f,t,w] >= z_segment_state[u,i,t,w]*segment_units[u].min_input[i,f])
    @constraint(h4c_real, segment_unit_in_max[u=1:U_segment,i=1:I, f=1:F, t=1:T, w=1:W], x_segment_in[u,i,f,t,w] <= z_segment_state[u,i,t,w]*segment_units[u].max_input[i,f])
    
    
    
    @constraint(h4c_real, segment_unit_out_min[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f]) >= sum(z_segment_state[u,i,t,w]*segment_units[u].min_output[i,f] for i in 1:I))
    @constraint(h4c_real, segment_unit_out_max[u=1:U_segment, f=1:F, t=1:T, w=1:W], sum(x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f]) <= sum(z_segment_state[u,i,t,w]*segment_units[u].max_output[i,f] for i in 1:I))
    

    @constraint(h4c_real, segment_unit_segment_determiner_min[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w]*segment_units[u].min_state[i] for i in 1:I) <= y[segment_units[u].segment_determiner,t,w])

    # When the unit is off, the big-M term (the storage capacity) relaxes the upper bound
    # to the regular capacity constraint, so the storage need not be empty.
    @constraint(h4c_real, segment_unit_segment_determiner_max[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w]*segment_units[u].max_state[i] for i in 1:I) + storages[segment_units[u].segment_determiner].energy_cap*(1 - z_segment_on[u,t,w]) >= y[segment_units[u].segment_determiner,t,w])
                                                                                        

    @constraint(h4c_real, segment_unit_state_on[u=1:U_segment, t=1:T, w=1:W], sum(z_segment_state[u,i,t,w] for i in 1:I) == z_segment_on[u,t,w])

    
    @constraint(h4c_real, segment_unit_start_stop[u=1:U_segment, t=2:T, w=1:W], z_segment_start[u,t,w] - z_segment_stop[u,t,w] == z_segment_on[u,t,w]- z_segment_on[u,t-1,w])
    @constraint(h4c_real, segment_unit_start_stop_ini[u=1:U_segment, w=1:W],    z_segment_start[u,1,w] - z_segment_stop[u,1,w] == z_segment_on[u,1,w]- ini_vec[:z_segment_on][u,end])

    @constraint(h4c_real, segment_unit_ss_sum[u=1:U_segment, t=1:T, w=1:W],     z_segment_start[u,t,w] + z_segment_stop[u,t,w] <= 1)

    @constraint(h4c_real, segment_unit_ramp_up[u=1:U_segment, f=1:F, t=2:T, w=1:W],   sum(x[a,t,w] - x[a,t-1,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_up[f] + z_segment_start[u,t,w]*segment_units[u].min_ramp[f])
    @constraint(h4c_real, segment_unit_ramp_down[u=1:U_segment, f=1:F, t=2:T, w=1:W], sum(x[a,t-1,w] - x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_down[f] + z_segment_stop[u,t,w]*segment_units[u].min_ramp[f])

    @constraint(h4c_real, segment_unit_ramp_up_ini[u=1:U_segment, f=1:F, t=1:1, w=1:W],   sum(x[a,t,w] - ini_vec[:x][a,end] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_up[f] + z_segment_start[u,t,w]*segment_units[u].min_ramp[f])
    @constraint(h4c_real, segment_unit_ramp_down_ini[u=1:U_segment, f=1:F, t=1:1, w=1:W], sum(ini_vec[:x][a,end] - x[a,t,w] for a in 1:A if lines[a].from == segment_units[u].node  && lines[a].carrier == carriers[f]) <= segment_units[u].ramp_down[f] + z_segment_stop[u,t,w]*segment_units[u].min_ramp[f])
    
    # Segment unit min down/up time constraints
    @constraint(h4c_real, segment_min_down_t[u=1:U_segment, t=1:T, w=1:W],
        sum(z_segment_on[u,t1,w] for t1 in t:min(t+segment_units[u].min_down_time-1, T))
        <= min(segment_units[u].min_down_time, T-t+1) * (1 - z_segment_stop[u,t,w]))

    @constraint(h4c_real, segment_min_up_t[u=1:U_segment, t=1:T, w=1:W],
        sum(z_segment_on[u,t1,w] for t1 in t:min(t+segment_units[u].min_up_time-1, T))
        >= min(segment_units[u].min_up_time, T-t+1) * z_segment_start[u,t,w])

    # Segment carry-over from previous day
    @constraint(h4c_real, segment_min_down_t_ini[u=1:U_segment, t=1:T, w=1:W; t <= segment_units[u].min_down_time-1],
        sum(z_segment_on[u,t1,w] for t1 in 1:t)
        <= t * (1 - ini_vec[:z_segment_stop][u, end-segment_units[u].min_down_time+1+t]))

    @constraint(h4c_real, segment_min_up_t_ini[u=1:U_segment, t=1:T, w=1:W; t <= segment_units[u].min_up_time-1],
        sum(z_segment_on[u,t1,w] for t1 in 1:t)
        >= t * ini_vec[:z_segment_start][u, end-segment_units[u].min_up_time+1+t])

    
    @constraint(h4c_real, line_min_flow[a=1:A, t=1:T, w=1:W], x[a,t,w] >= lines[a].min_cap)
    @constraint(h4c_real, line_max_flow[a=1:A, t=1:T, w=1:W], x[a,t,w] <= lines[a].max_cap)

    if W > 1
        @constraint(h4c_real, units_sequential[u=1:U, t=1:T_hn, w=2:W],                  z[u,t,w-1]             == z[u,t,w])
        @constraint(h4c_real, transport_sequential[u=1:U_trans, r=1:R, t=1:T_hn, w=2:W], z_transport[u,r,t,w-1] == z_transport[u,r,t,w])
        @constraint(h4c_real, multi_unit_sequential[u=1:U_multi, t=1:T_hn, w=2:W],       z_multi_on[u,t,w-1]    == z_multi_on[u,t,w])
        @constraint(h4c_real, segment_unit_sequential[u=1:U_segment, t=1:T_hn, w=2:W], z_segment_on[u,t,w-1]    == z_segment_on[u,t,w])
        @constraint(h4c_real, cg_unit_sequential[u=1:U_CG, t=1:T_hn, w=2:W],             z_cg[u,t,w-1]          == z_cg[u,t,w])
    end

    lock_variables!(vars_det, first_stage_values, idxs_first_stage) #Locks first stage values defined in main

    # first_stage_values[:x] can carry sub-tolerance solver noise (e.g. -1e-6 on an arc
    # that should be exactly 0), which turns an exact equality lock into a hard infeasibility
    # against x's own >=0 bound or against arcs implied to 0 by locked commitment binaries.
    # Clip the noise and allow a small absolute+relative band instead of an exact equality.
    fsv_x_clean = max.(first_stage_values[:x], 0.0)
    tol_abs = 1e-4
    tol_rel = 0.001

    @expression(h4c_real, source_hn_target[e=1:E, t=1:T_hn, w=1:W],
        sum(fsv_x_clean[a,t,w] for a in 1:A if lines[a].from == sources[e].node) * sources[e].here_and_now)
    @expression(h4c_real, source_hn_flow[e=1:E, t=1:T_hn, w=1:W],
        sum(x[a,t,w] for a in 1:A if lines[a].from == sources[e].node) * sources[e].here_and_now)

    @constraint(h4c_real, source_here_and_now_lock_lo[e=1:E, t=1:T_hn, w=1:W],
        source_hn_flow[e,t,w] >= source_hn_target[e,t,w] - (tol_abs + tol_rel*source_hn_target[e,t,w]))
    @constraint(h4c_real, source_here_and_now_lock_hi[e=1:E, t=1:T_hn, w=1:W],
        source_hn_flow[e,t,w] <= source_hn_target[e,t,w] + (tol_abs + tol_rel*source_hn_target[e,t,w]))

    if W > 1
        #@constraint(h4c_real, source_here_and_now_lock[e=1:E, t=1:T_hn, w=2:W], sum(x[a,t,w] for a in 1:A if lines[a].from  == sources[e].node)*sources[e].here_and_now == sum(first_stage_values[:x][a,t,w] for a in 1:A if lines[a].from  == sources[e].node)*sources[e].here_and_now)

        @constraint(h4c_real, x_hn_lock[a=1:A, t=1:T_hn, w=2:W],               x[a,t,w] == x[a,t,w-1])
        @constraint(h4c_real, y_hn_lock[s=1:S, t=1:T_hn, w=2:W],               y[s,t,w] == y[s,t,w-1])
        @constraint(h4c_real, alpha_hn_lock[u=1:U_CG, g=1:G, t=1:T_hn, w=2:W], alpha[u,g,t,w] == alpha[u,g,t,w-1])
        @constraint(h4c_real, x_multi_main_lock[u=1:U_multi, q=1:Q, t=1:T_hn, w=2:W], x_multi_main[u,q,t,w-1] == x_multi_main[u,q,t,w])
        @constraint(h4c_real, x_segment_in_lock[u=1:U_segment, i=1:I, f=1:F, t=1:T_hn, w=2:W], x_segment_in[u,i,f,t,w-1] == x_segment_in[u,i,f,t,w])
    end


    apply_time_limit!(h4c_real, time_limit)


    t_start_opt = time()
    optimize!(h4c_real)
    t_end = time()
    solve_time = t_end - t_start_opt
    # Print the conflicting constraints of an infeasible model (conflict refiner: Gurobi only)
    if termination_status(h4c_real) == MOI.INFEASIBLE && solver_name(h4c_real) == "Gurobi"
        compute_conflict!(h4c_real)
        if MOI.get(h4c_real, MOI.ConflictStatus()) == MOI.CONFLICT_FOUND
            for con_ref in all_constraints(h4c_real; include_variable_in_set_constraints=true)
                if MOI.get(h4c_real, MOI.ConstraintConflictStatus(), con_ref) == MOI.IN_CONFLICT
                    println(con_ref)
                end
            end
        end
    end
    # Capture MIP gap
    mip_gap = get_mip_gap(h4c_real)   # Defined in EM_in_H4C_model_stochastic.jl

    if !has_values(h4c_real)
        empty_full = Dict(
            :x               => zeros(size(x)),
            :y               => zeros(size(y)),
            :z               => zeros(size(z)),
            :z_start         => zeros(size(z_start)),
            :z_stop          => zeros(size(z_stop)),
            :alpha           => zeros(size(alpha)),
            :z_cg            => zeros(size(z_cg)),
            :z_cg_start      => zeros(size(z_cg_start)),
            :z_cg_stop       => zeros(size(z_cg_stop)),
            :x_multi_main    => zeros(size(x_multi_main)),
            :z_multi_on      => zeros(size(z_multi_on)),
            :z_multi_h_start => zeros(size(z_multi_h_start)),
            :z_multi_c_start => zeros(size(z_multi_c_start)),
            :z_multi_h_stop  => zeros(size(z_multi_h_stop)),
            :z_multi_c_stop  => zeros(size(z_multi_c_stop)),
            :z_multi_state   => zeros(size(z_multi_state)),
            :x_segment_in    => zeros(size(x_segment_in)),
            :z_segment_on    => zeros(size(z_segment_on)),
            :z_segment_start => zeros(size(z_segment_start)),
            :z_segment_stop  => zeros(size(z_segment_stop)),
            :z_segment_state => zeros(size(z_segment_state)),
            :z_transport     => zeros(size(z_transport)),
            :v_up            => zeros(size(v_up)),
            :v_down          => zeros(size(v_down)),
            :status          => [termination_status(h4c_real)],
            :objective       => [NaN]
        )
        empty_res = Dict(
            :x               => zeros(size(x, 1), T_hn),
            :y               => zeros(size(y, 1), T_hn),
            :z               => zeros(size(z, 1), T_hn),
            :z_start         => zeros(size(z_start, 1), T_hn),
            :z_stop          => zeros(size(z_stop, 1), T_hn),
            :alpha           => zeros(size(alpha, 1), size(alpha, 2), T_hn),
            :z_cg            => zeros(size(z_cg, 1), T_hn),
            :z_cg_start      => zeros(size(z_cg_start, 1), T_hn),
            :z_cg_stop       => zeros(size(z_cg_stop, 1), T_hn),
            :x_multi_main    => zeros(size(x_multi_main, 1), size(x_multi_main, 2), T_hn),
            :z_multi_on      => zeros(size(z_multi_on, 1), T_hn),
            :z_multi_h_start => zeros(size(z_multi_h_start, 1), T_hn),
            :z_multi_c_start => zeros(size(z_multi_c_start, 1), T_hn),
            :z_multi_h_stop  => zeros(size(z_multi_h_stop, 1), T_hn),
            :z_multi_c_stop  => zeros(size(z_multi_c_stop, 1), T_hn),
            :z_multi_state   => zeros(size(z_multi_state, 1), size(z_multi_state, 2), T_hn),
            :x_segment_in    => zeros(size(x_segment_in, 1), size(x_segment_in, 2), size(x_segment_in, 3), T_hn),
            :z_segment_on    => zeros(size(z_segment_on, 1), T_hn),
            :z_segment_start => zeros(size(z_segment_start, 1), T_hn),
            :z_segment_stop  => zeros(size(z_segment_stop, 1), T_hn),
            :z_segment_state => zeros(size(z_segment_state, 1), size(z_segment_state, 2), T_hn),
            :z_transport     => zeros(size(z_transport, 1), size(z_transport, 2), T_hn),
            :v_up            => zeros(size(v_up, 1), T_hn),
            :v_down          => zeros(size(v_down, 1), T_hn),
            :status          => [termination_status(h4c_real)],
            :objective       => [NaN],
            :solve_time      => [solve_time],
            :mip_gap         => [NaN]
        )
        return empty_full, empty_res
    end

    real_results_full = Dict(
        :x                        => value.(x),
        :y                        => value.(y),
        :z                        => value.(z),
        :z_start                  => value.(z_start),
        :z_stop                   => value.(z_stop),
        :alpha                    => value.(alpha),
        :z_cg                     => value.(z_cg),
        :z_cg_start               => value.(z_cg_start),
        :z_cg_stop                => value.(z_cg_stop),
        :x_multi_main             => value.(x_multi_main),
        :z_multi_on               => value.(z_multi_on),
        :z_multi_h_start          => value.(z_multi_h_start),
        :z_multi_c_start          => value.(z_multi_c_start),
        :z_multi_h_stop           => value.(z_multi_h_stop),
        :z_multi_c_stop           => value.(z_multi_c_stop),
        :z_multi_state            => value.(z_multi_state),
        :x_segment_in    => value.(x_segment_in),
        :z_segment_on    => value.(z_segment_on),
        :z_segment_start => value.(z_segment_start),
        :z_segment_stop  => value.(z_segment_stop),
        :z_segment_state => value.(z_segment_state),
        :z_transport              => value.(z_transport),
        :v_up                     => value.(v_up),
        :v_down                   => value.(v_down),
        :status                   => [termination_status(h4c_real)],  # wrapped in vector
        :objective                => [objective_value(h4c_real)]      # wrapped in vector
    )

    if !isempty(multi_units)
        multi_unit_obj = value.(sum(pi[w]*(sum(multi_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_multi, f in 1:F, t in 1:T_hn, a in 1:A if lines[a].from == multi_units[u].node && lines[a].carrier == carriers[f])+
                                sum(z_multi_c_stop[u,t,w]*multi_units[u].start_stop_cost[2] for u in 1:U_multi, t in 1:T_hn) + 
                                sum(z_multi_h_stop[u,t,w]*multi_units[u].start_stop_cost[1] for u in 1:U_multi, t in 1:T_hn)) for w in 1:W))
    else
        multi_unit_obj = 0
    end

    if !isempty(cg_units)
        cg_unit_obj = value.(sum(pi[w]*(sum(cg_units[u].start_stop_cost*z_cg_stop[u,t,w] for u in 1:U_CG) +
                         sum(cg_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_CG, f in 1:F, a in 1:A if lines[a].from == cg_units[u].node && lines[a].carrier == carriers[f])) for t in 1:T_hn, w in 1:W))
    else
        cg_unit_obj = 0
    end

    if !isempty(segment_units)
        segment_unit_obj = value.(sum(pi[w]*(sum(segment_units[u].start_stop_cost*z_segment_stop[u,t,w] for u in 1:U_segment) +
                         sum(segment_units[u].cost_operating[f]*x[a,t,w] for u in 1:U_segment, f in 1:F, a in 1:A if lines[a].from == segment_units[u].node && lines[a].carrier == carriers[f])) for t in 1:T_hn, w in 1:W))
    else
        segment_unit_obj = 0
    end

    if !isempty(transport_units)
        transport_unit_obj = value.(sum(pi[w]*(sum(z_transport[u,r,t,w]*(transport_units[u].cost_fixed + transport_units[u].cost_distance*lines[route_lines[u,r]].distance + transport_units[u].cost_time*tau_routes[u,r]) for u in 1:U_trans, r in 1:R if route_lines[u,r] > 0)) for t in 1:T_hn, w in 1:W))
    else
        transport_unit_obj = 0
    end

    objective_hn = (value.(sum(pi[w]*(sum(lines[a].cost*x[a,t,w] for a in 1:A) +
                        sum(sources[e].price[t,w]*x[a,t,w] for e in 1:E, a in 1:A if lines[a].from == sources[e].node) +
                        sum(units[u].start_stop_cost*z_stop[u,t,w] for u in 1:U)+
                        sum(units[u].cost_operating[f]*x[a,t,w] for u in 1:U, f in 1:F, a in 1:A if lines[a].from == units[u].node && lines[a].carrier == carriers[f]) + -
                        sum(demands[d].price[t,w]*x[a,t,w] for d in 1:D, a in 1:A if lines[a].to == demands[d].node)) for t in 1:T_hn, w in 1:W)) +
                        multi_unit_obj + cg_unit_obj + segment_unit_obj + transport_unit_obj)

    


    real_results = Dict(
        :x                        => value.(x[:,1:T_hn,1]),
        :y                        => value.(y[:,1:T_hn,1]),
        :z                        => value.(z[:,1:T_hn,1]),
        :z_start                  => value.(z_start[:,1:T_hn,1]),
        :z_stop                   => value.(z_stop[:,1:T_hn,1]),
        :alpha                    => value.(alpha[:,:,1:T_hn,1]),
        :z_cg                     => value.(z_cg[:,1:T_hn,1]),
        :z_cg_start               => value.(z_cg_start[:,1:T_hn,1]),
        :z_cg_stop                => value.(z_cg_stop[:,1:T_hn,1]),
        :x_multi_main             => value.(x_multi_main[:,:,1:T_hn,1]),
        :z_multi_on               => value.(z_multi_on[:,1:T_hn,1]),
        :z_multi_h_start          => value.(z_multi_h_start[:,1:T_hn,1]),
        :z_multi_c_start          => value.(z_multi_c_start[:,1:T_hn,1]),
        :z_multi_h_stop           => value.(z_multi_h_stop[:,1:T_hn,1]),
        :z_multi_c_stop           => value.(z_multi_c_stop[:,1:T_hn,1]),
        :z_multi_state            => value.(z_multi_state[:,:,1:T_hn,1]),
        :x_segment_in    => value.(x_segment_in[:,:,:,1:T_hn,1]),
        :z_segment_on    => value.(z_segment_on[:,1:T_hn,1]),
        :z_segment_start => value.(z_segment_start[:,1:T_hn,1]),
        :z_segment_stop  => value.(z_segment_stop[:,1:T_hn,1]),
        :z_segment_state => value.(z_segment_state[:,:,1:T_hn,1]),
        :z_transport              => value.(z_transport[:,:,1:T_hn,1]),
        :v_up                     => value.(v_up[:,1:T_hn,1]),
        :v_down                   => value.(v_down[:,1:T_hn,1]),
        :status                   => [termination_status(h4c_real)],  # wrapped in vector
        :objective                => [objective_hn],      # wrapped in vector
        :solve_time               => [solve_time],
        :mip_gap                  => [mip_gap]
    )

    return real_results_full, real_results
end

