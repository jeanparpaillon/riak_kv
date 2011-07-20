-module(fsmlog).
-behaviour(gen_server).

%% API
-export([run/0, run/1]).
-export([start_link/0, start/0, stop/0]).
-export([trace_fsms/0, trace_fsms/1,
         trace_bitcask/0, trace_bitcask/1,
         report_fsms/0, log_trace/1, log_vnodes/1, log_stats/1,
         timestamp/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {local_epoch, %% Local gregorian seconds at 1/1/1970
                trace_fh,
                stats_fh,
                vnode_fh,
                fsms_tref,
                fsms_interval,
                bc_tref,
                bc_interval,
                vnode_tref,
                vnode_interval,
                vnode_idxs = [], % { Pid, VnodeIdx}
                get_fsm_5min = new_hist(),
                put_fsm_5min = new_hist(),
                bc_get_5min = new_hist(),
                bc_getnf_5min = new_hist(),
                bc_put_5min = new_hist()
               }).



%%%===================================================================
%%% API
%%%===================================================================
run() ->
    run("/tmp/riak").

run(LogDir) ->
    {ok, _Pid} = start(),
    trace_fsms(),
    trace_bitcask(),
    log_trace(filename:join(LogDir, "trace.log.gz")),
    log_stats(filename:join(LogDir, "stats.log")),
    log_vnodes(filename:join(LogDir, "vnodes.log.gz")),
    ok.
    
start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:call(?MODULE, stop).

trace_fsms() ->
    trace_fsms(timer:minutes(5)).

trace_fsms(Interval) ->
    gen_server:call(?MODULE, {trace_fsms, Interval}).

trace_bitcask() ->
    trace_bitcask(timer:minutes(5)).

trace_bitcask(Interval) ->
    gen_server:call(?MODULE, {trace_bitcask, Interval}).

report_fsms() ->
    gen_server:call(?MODULE, report_fsms).

log_trace(Filename) ->
    gen_server:call(?MODULE, {log_trace, Filename}).

log_stats(Filename) ->
    gen_server:call(?MODULE, {log_stats, Filename}).

log_vnodes(Filename) ->
    log_vnodes(Filename, timer:seconds(5)).

log_vnodes(Filename, Interval) ->
    gen_server:call(?MODULE, {log_vnodes, Filename, Interval}).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    dbg:stop_clear(),
    dbg:tracer(process, {fun stat_trace/2, gb_trees:empty()}),
    dbg:p(all, call),
    {0, TimeDiff} = calendar:time_difference(calendar:local_time(), calendar:universal_time()),
    TimeDiffSecs = calendar:time_to_seconds(TimeDiff),
    Epoch = calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}) - TimeDiffSecs,
    {ok, #state{local_epoch = Epoch}}.

handle_call({trace_fsms, Interval}, _From, State) ->
    State1 = schedule_reset_fsm_hists(State#state{fsms_interval = Interval}),
    dbg:tpl(riak_kv_stat, update, 3, []),
    {reply, ok, State1};
handle_call({trace_bitcask, Interval}, _From, State) ->
    State1 = schedule_reset_bc_hists(State#state{bc_interval = Interval}),
    dbg:tpl(bitcask, get, 2, [{'_', [], [{return_trace}]}]),
    dbg:tpl(bitcask, put, 3, [{'_', [], [{return_trace}]}]),
    {reply, ok, State1};
handle_call(report_fsms, _From, State = #state{get_fsm_5min = Get5,
                                               put_fsm_5min = Put5}) ->
    Reply = [hist_summary(get5, Get5),
             hist_summary(put5, Put5)],
    {reply, Reply, State};
handle_call({log_trace, Filename}, _From, State = #state{trace_fh = OldFh}) ->
    catch file:close(OldFh),
    case open(Filename, [write, raw, binary, delayed_write]) of
        {ok, Fh} ->
            {reply, ok, State#state{trace_fh = Fh}};
        ER ->
            error_logger:error_msg("~p: Could not open FSM trace log ~p: ~p",
                                   [?MODULE, Filename, ER]),
            {reply, ER, State#state{trace_fh = undefined}}
    end;
handle_call({log_vnodes, Filename, Interval}, _From, State = #state{vnode_fh = OldFh}) ->
    State1 = schedule_log_vnodes(State#state{vnode_interval = Interval}),
    catch file:close(OldFh),
    case open(Filename, [write, raw, binary]) of
        {ok, Fh} ->
            {reply, ok, State1#state{vnode_fh = Fh}};
        ER ->
            error_logger:error_msg("~p: Could not open vnode stats log ~p: ~p",
                                   [?MODULE, Filename, ER]),
            {reply, ER, State1#state{vnode_fh = undefined}}
    end;
handle_call({log_stats, Filename}, _From, State = #state{stats_fh = OldFh}) ->
    catch file:close(OldFh),
    case open(Filename, [write, raw, binary]) of
        {ok, Fh} ->
            {reply, ok, State#state{stats_fh = Fh}};
        ER ->
            error_logger:error_msg("~p: Could not open FSM stats log ~p: ~p",
                                   [?MODULE, Filename, ER]),
            {reply, ER, State#state{stats_fh = undefined}}
    end;
handle_call(stop, _From, State) ->
    dbg:stop_clear(),
    {stop, normal, ok, State}.


handle_cast(_Msg, State) ->
    {stop, {unexpected, _Msg}, State}.

handle_info({get_fsm_usecs, Moment, Usecs}, State = #state{get_fsm_5min = FiveMinHist}) ->
    State1 = trace_log_fsm(get_fsm, Moment, Usecs, State),
    {noreply, State1#state{get_fsm_5min = basho_stats_histogram:update(Usecs, FiveMinHist)}};
handle_info({put_fsm_usecs, Moment, Usecs}, State = #state{put_fsm_5min = FiveMinHist}) ->
    State1 = trace_log_fsm(put_fsm, Moment, Usecs, State),
    {noreply, State1#state{put_fsm_5min = basho_stats_histogram:update(Usecs, FiveMinHist)}};


handle_info({bitcask, bc_getnf=Op, Timestamp, Usecs},
            State = #state{bc_getnf_5min = FiveMinHist}) ->
    State1 = trace_log(Op, Timestamp, Usecs, State),
    {noreply, State1#state{bc_getnf_5min = basho_stats_histogram:update(Usecs, FiveMinHist)}};
handle_info({bitcask, bc_get=Op, Timestamp, Usecs}, State = #state{bc_get_5min = FiveMinHist}) ->
    State1 = trace_log(Op, Timestamp, Usecs, State),
    {noreply, State1#state{bc_get_5min = basho_stats_histogram:update(Usecs, FiveMinHist)}};
handle_info({bitcask, bc_put=Op, Timestamp, Usecs},
            State = #state{bc_put_5min = FiveMinHist}) ->
    State1 = trace_log(Op, Timestamp, Usecs, State),
    {noreply, State1#state{bc_put_5min = basho_stats_histogram:update(Usecs, FiveMinHist)}};
%% Track errors separately, no hist update
handle_info({bitcask, Op, Timestamp, Usecs}, State) ->
    {noreply, trace_log(Op, Timestamp, Usecs, State)};
handle_info(reset_fsm_hists, State = #state{stats_fh = Fh,
                                            get_fsm_5min = Get5,
                                            put_fsm_5min = Put5}) ->
    State1 = schedule_reset_fsm_hists(State),
    TS = timestamp(),
    log_hist_stats(TS, getfsm, Get5, Fh),
    log_hist_stats(TS, putfsm, Put5, Fh),
    {noreply, State1#state{get_fsm_5min = new_hist(),
                           put_fsm_5min = new_hist()}};
handle_info(reset_bc_hists, State = #state{stats_fh = Fh,
                                           bc_get_5min = Get5,
                                           bc_getnf_5min = GetNF5,
                                           bc_put_5min = Put5}) ->
    State1 = schedule_reset_bc_hists(State),
    TS = timestamp(),
    log_hist_stats(TS, bcget, Get5, Fh),
    log_hist_stats(TS, bcgetnf, GetNF5, Fh),
    log_hist_stats(TS, bcput, Put5, Fh),
    {noreply, State1#state{bc_get_5min = new_hist(),
                           bc_getnf_5min = new_hist(),
                           bc_put_5min = new_hist()}};

handle_info(log_vnodes, State = #state{vnode_fh = Fh}) ->
    State1 = schedule_log_vnodes(State),
    Pids = get_vnode_pids(),
    TS = timestamp(),
    Prefix = integer_to_list(TS),
    {VnodeInfo, State2} = lists:foldl(fun make_vnode_entry/2, {[], State1}, Pids),
    Entries = [ [Prefix, $,, integer_to_list(VIdx), $,, integer_to_list(MsgQ), $\n] || 
                  {VIdx, MsgQ} <- lists:sort(VnodeInfo) ],
    case file:write(Fh, Entries) of
        ok ->
            {noreply, State2};
        ER ->
            error_logger:error_msg("~p: Could not log vnodes: ~p\n", [?MODULE, ER]),
            {noreply, State1}
    end.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

timestamp() ->
    {Mega, Sec, _} = now(),
    (Mega * 1000000) + Sec.


hist_summary(What, Hist) ->
    {Min, Mean, Max, _, _} = basho_stats_histogram:summary_stats(Hist),
    [{What, obs, basho_stats_histogram:observations(Hist)},
     {What, min, maybe_trunc(Min)},
     {What, mean, maybe_trunc(Mean)},
     {What, max, maybe_trunc(Max)}] ++
        [{What, Pctl, maybe_trunc(basho_stats_histogram:quantile(Pctl, Hist))} || 
            Pctl <- [0.500, 0.950, 0.990, 0.999]].

log_hist_stats(TS, What, Hist, Fh) ->
    {Min, Mean, Max, _, _} = basho_stats_histogram:summary_stats(Hist),
    Data = [TS, 
            What, 
            basho_stats_histogram:observations(Hist),
            maybe_trunc(Min),
            maybe_trunc(Mean),
            maybe_trunc(Max)] ++
        [maybe_trunc(basho_stats_histogram:quantile(Pctl, Hist)) ||
            Pctl <- [0.500, 0.950, 0.990, 0.999]],
    output_csv(Data, Fh).

output_csv(Cols, Fh) ->
    Out = [io_lib:format("~p", [hd(Cols)]) | [io_lib:format(",~p", [Col]) || Col <- tl(Cols)]],
    file:write(Fh, [Out, $\n]).
     

maybe_trunc('NaN') ->
    0;
maybe_trunc(Val) ->
    try
        trunc(Val)
    catch _:_ ->
            Val
    end.

trace_log_fsm(_Op, _Moment, _Usecs, State = #state{trace_fh = undefined}) ->
    State;
trace_log_fsm(Op, Moment, Usecs, State = #state{local_epoch = Epoch}) ->
    TS = Moment - Epoch,
    trace_log(Op, TS, Usecs, State).

trace_log(_Op, _TS, _Usecs, State = #state{trace_fh = undefined}) ->
    State;
trace_log(Op, TS, Usecs, State = #state{trace_fh = Fh}) ->
    Entry = io_lib:format("~b,~p,~b\n", [TS, Op, Usecs]),
    case file:write(Fh, Entry) of
        ok ->
            State;
        ER ->
            error_logger:error_msg("Could not write entry - ~p.  Disabling trace log to disk.\n",
                                   [ER]),
            catch file:close(Fh),
            State#state{trace_fh = undefined}
    end.

make_vnode_entry(Pid, {Entries, State}) ->
    try
        {VIdx, State1} = find_vidx(Pid, State),
        {message_queue_len, MsgQ} = erlang:process_info(Pid, message_queue_len),
        {[{VIdx, MsgQ} | Entries], State1}
    catch _:Err ->
            error_logger:error_msg("~p: could not log vnode msgq: ~p\n", [?MODULE, Err]),
            {Entries,  State}
    end.


find_vidx(Pid, State = #state{vnode_idxs = VIdxs}) ->
    case orddict:find(Pid, VIdxs) of
        {ok, VIdxStr} ->
            {VIdxStr, State};
        error ->
            {_Mod, Vnode} = riak_core_vnode:get_mod_index(Pid),
            VIdx = vnode_to_vidx(Vnode),
            {VIdx, State#state{vnode_idxs = orddict:store(Pid, VIdx, VIdxs)}}
    end.

vnode_to_vidx(Vnode) ->
    {ok, R} = riak_core_ring_manager:get_my_ring(),
    Q = riak_core_ring:num_partitions(R),
    Wedge = trunc(math:pow(2,160)) div Q, % how much keyspace for each vnode
    Vnode div Wedge. % convert to small integer from 0..Q-1

get_vnode_pids() ->
    [Pid || {undefined, Pid, worker, dynamic} <- supervisor:which_children(riak_core_vnode_sup)].

stat_trace({trace, _Pid, call, {_Mod, _Fun, [{get_fsm_time, Usecs}, Moment, _State]}}, Acc) ->
    ?MODULE ! {get_fsm_usecs, Moment, Usecs},
    Acc;
stat_trace({trace, _Pid, call, {_Mod, _Fun, [{put_fsm_time, Usecs}, Moment, _State]}}, Acc) ->
    ?MODULE ! {put_fsm_usecs, Moment, Usecs},
    Acc;
stat_trace({trace, Pid, call, {bitcask, Fun, _}}=_Msg, Acc) ->
%    io:format("BC: ~p\n", [Msg]),
    gb_trees:insert({Pid, bc, Fun}, os:timestamp(), Acc);
stat_trace({trace, Pid, return_from, {bitcask, Fun, _}, Result}=_Msg, Acc) ->
    Op = case {Fun, Result} of
             {put, ok} ->
                 bc_put;
             {put, _} ->
                 bc_puterr;
             {get, {ok, _}} ->
                 bc_get;
             {get, not_found} ->
                 bc_getnf;
             {get, _} ->
                 bc_geterr
         end,
    case gb_trees:lookup({Pid, bc, Fun}, Acc) of
        {value, StartTime} ->
            Usecs = timer:now_diff(os:timestamp(), StartTime),
            ?MODULE ! {bitcask, Op, timestamp(), Usecs};
        none ->
            ok
    end,
    Acc1 = gb_trees:delete({Pid, bc, Fun}, Acc),
%    io:format("BC ~p: return_from ~p\nAcc: ~p\n", [Op, Msg, Acc1]),
    Acc1;
stat_trace({trace, _Pid, call, {_Mod, _Fun, _Args}}, Acc) ->
    %% io:format(user, "missed: ~p\n", [{_Mod, _Fun, _Args}]),
    Acc.

new_hist() ->
    %% Tracks latencies up to 5 secs w/ 250 us resolution
    basho_stats_histogram:new(0, 5000000, 20000).
  
schedule_reset_fsm_hists(State = #state{fsms_tref = OldTref, fsms_interval = Interval}) ->
    maybe_cancel_timer(OldTref),
    Tref = erlang:send_after(Interval, self(), reset_fsm_hists),
    State#state{fsms_tref = Tref}.

schedule_reset_bc_hists(State = #state{bc_tref = OldTref, bc_interval = Interval}) ->
    maybe_cancel_timer(OldTref),
    Tref = erlang:send_after(Interval, self(), reset_bc_hists),
    State#state{bc_tref = Tref}.

schedule_log_vnodes(State = #state{vnode_tref = OldTref, vnode_interval = Interval}) ->
    maybe_cancel_timer(OldTref),
    Tref = erlang:send_after(Interval, self(), log_vnodes),
    State#state{vnode_tref = Tref}.

maybe_cancel_timer(undefined) ->
    ok;
maybe_cancel_timer(Tref) ->
    erlang:cancel_timer(Tref).

open(Filename, Options) ->
    case filename:extension(Filename) of
        ".gz" ->
            file:open(Filename, [compressed | Options]);
        _ ->
            file:open(Filename, Options)
    end.
               
%% -module(logfsms).

%% timeit(Mod, Fun, Arity) ->
%%     dbg:tracer(process, {fun trace/2, []}),
%%     dbg:p(all, call),
%%     dbg:tpl(Mod, Fun, Arity, [{'_', [], [{return_trace}]}]).






%% %% do_put, do_put
