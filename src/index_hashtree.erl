-module(index_hashtree).
-behaviour(gen_server).

-include_lib("riak_kv_vnode.hrl").

%% API
-export([start_link/1, get_exchange_lock/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {index,
                built,
                lock,
                verified,
                exchange_queue,
                exchanging :: undefined | reference(), %% Rename since it's not just exchanging (eg. reverify)
                trees}).

-compile(export_all).

%% TODO: For testing/dev, make this small. For prod, we should raise this.
-define(TICK_TIME, 10000).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Index) ->
    gen_server:start_link(?MODULE, [Index], []).

new_tree(Id, Tree) ->
    gen_server:call(Tree, {new_tree, Id}, infinity).

insert(Id, Key, Hash, Tree) ->
    gen_server:cast(Tree, {insert, Id, Key, Hash}).

insert_object(BKey, RObj, Tree) ->
    gen_server:cast(Tree, {insert_object, BKey, RObj}).

start_exchange_remote(FsmPid, IndexN, Tree) ->
    gen_server:call(Tree, {start_exchange_remote, FsmPid, IndexN}, infinity).

update(Id, Tree) ->
    gen_server:call(Tree, {update_tree, Id}, infinity).

build(Tree) ->
    gen_server:cast(Tree, build).

exchange_bucket(Id, Level, Bucket, Tree) ->
    gen_server:call(Tree, {exchange_bucket, Id, Level, Bucket}, infinity).

exchange_segment(Id, Segment, Tree) ->
    gen_server:call(Tree, {exchange_segment, Id, Segment}, infinity).

compare(Id, Remote, Tree) ->
    gen_server:call(Tree, {compare, Id, Remote}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Index]) ->
    %% schedule_tick(),
    entropy_manager:register_tree(Index, self()),
    {ok, #state{index=Index,
                trees=orddict:new(),
                built=false,
                exchange_queue=[]}}.

hash_object(RObjBin) ->
    RObj = binary_to_term(RObjBin),
    Vclock = riak_object:vclock(RObj),
    UpdObj = riak_object:set_vclock(RObj, lists:sort(Vclock)),
    Hash = erlang:phash2(term_to_binary(UpdObj)),
    term_to_binary(Hash).

fold_keys(Partition, Tree) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    Req = ?FOLD_REQ{foldfun=fun(BKey={Bucket,Key}, RObj, _) ->
                                    IndexN = get_index_n({Bucket, Key}, Ring),
                                    insert(IndexN, term_to_binary(BKey), hash_object(RObj), Tree),
                                    ok
                            end,
                    acc0=ok},
    %% spawn_link(
    %%   fun() ->
    %%           riak_core_vnode_master:sync_command({Partition, node()},
    %%                                               Req,
    %%                                               riak_kv_vnode_master, infinity),
    %%           ok
    %%   end).
    %%
    %% Need to block for now to ensure building happens before updating/compare.
    %% Easy to fix in the future to allow async building.
    %% Block here is bad because this fold sends casts to this very process.
    %% We're filling up our message queue and then handling everything after
    %% the entire fold. Very bad.
    riak_core_vnode_master:sync_command({Partition, node()},
                                        Req,
                                        riak_kv_vnode_master, infinity),
    ok.

handle_call({new_tree, Id}, _From, State=#state{trees=Trees}) ->
    IdBin = tree_id(Id),
    NewTree = case Trees of
                  [] ->
                      hashtree:new(IdBin);
                  [{_,Other}|_] ->
                      hashtree:new(IdBin, Other)
              end,
    Trees2 = orddict:store(Id, NewTree, Trees),
    State2 = State#state{trees=Trees2},
    {reply, ok, State2};

handle_call({start_exchange_remote, FsmPid, _IndexN}, _From, State) ->
    case State#state.exchanging of
        undefined ->
            case get_exchange_lock(State#state.index) of
                {error, max_concurrency} ->
                    {reply, max_concurrency, State};
                {ok, Lock} ->
                    Ref = monitor(process, FsmPid),
                    State2 = State#state{exchanging=Ref, lock=Lock},
                    {reply, ok, State2}
            end;
        _ ->
            {reply, already_exchanging, State}
    end;

handle_call({update_tree, Id}, _From, State) ->
    lager:info("Updating tree: (vnode)=~p (preflist)=~p", [State#state.index, Id]),
    apply_tree(Id,
               fun(Tree) ->
                       {ok, hashtree:update_tree(Tree)}
               end,
               State);

handle_call({exchange_bucket, Id, Level, Bucket}, _From, State) ->
    apply_tree(Id,
               fun(Tree) ->
                       Result = hashtree:get_bucket(Level, Bucket, Tree),
                       {Result, Tree}
               end,
               State);

handle_call({exchange_segment, Id, Segment}, _From, State) ->
    apply_tree(Id,
               fun(Tree) ->
                       [{_, Result}] = hashtree:key_hashes(Tree, Segment),
                       {Result, Tree}
               end,
               State);

handle_call({compare, Id, Remote}, From, State) ->
    Tree = orddict:fetch(Id, State#state.trees),
    spawn(fun() ->
                  Result = hashtree:compare(Tree, Remote),
                  gen_server:reply(From, Result)
          end),
    {noreply, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(tick, State) ->
    State2 = do_tick(State),
    %% schedule_tick(),
    {noreply, State2};

handle_cast(build, State) ->
    State2 = maybe_build(State),
    {noreply, State2};

handle_cast({insert, Id, Key, Hash}, State) ->
    State2 = do_insert(Id, Key, Hash, State),
    {noreply, State2};
handle_cast({insert_object, BKey, RObj}, State) ->
    lager:info("Inserting object ~p", [BKey]),
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    IndexN = get_index_n(BKey, Ring),
    State2 = do_insert(IndexN, term_to_binary(BKey), hash_object(RObj), State),
    {noreply, State2};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    State2 = do_tick(State),
    {noreply, State2};

handle_info({'DOWN', _Ref, _, _, _}, State=#state{exchanging=_Ref,
                                                 index=Index,
                                                 lock=Lock}) ->
    lager:info("DOWN"),
    (Lock == undefined) orelse release_lock(Index, Lock),
    State2 = State#state{exchanging=undefined,
                         lock=undefined},
    {noreply, State2};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _) ->
    ok.
%% terminate(_Reason, #state{trees=Trees}) ->
%%     case Trees of
%%         [] ->
%%             ok;
%%         [Tree|_] ->
%%             hashtree:destroy(Tree),
%%             ok
%%     end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

apply_tree(Id, Fun, State=#state{trees=Trees}) ->
    case orddict:find(Id, Trees) of
        error ->
            {reply, not_responsible, State};
        {ok, Tree} ->
            {Result, Tree2} = Fun(Tree),
            Trees2 = orddict:store(Id, Tree2, Trees),
            State2 = State#state{trees=Trees2},
            {reply, Result, State2}
    end.

do_insert(Id, Key, Hash, State=#state{trees=Trees}) ->
    lager:info("Insert into ~p/~p :: ~p / ~p", [State#state.index, Id, Key, Hash]),
    Tree = orddict:fetch(Id, Trees),
    Tree2 = hashtree:insert(Key, Hash, Tree),
    Trees2 = orddict:store(Id, Tree2, Trees),
    State#state{trees=Trees2}.

tree_id({Index, N}) ->
    %% hashtree is hardcoded for 22-byte (176-bit) tree id
    <<Index:160/integer,N:16/integer>>;
tree_id(_) ->
    erlang:error(badarg).

get_index_n(BKey) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    get_index_n(BKey, Ring).

get_index_n({Bucket, Key}, Ring) ->
    BucketProps = riak_core_bucket:get_bucket(Bucket, Ring),
    N = proplists:get_value(n_val, BucketProps),
    ChashKey = riak_core_util:chash_key({Bucket, Key}),
    Index = riak_core_ring:responsible_index(ChashKey, Ring),
    {Index, N}.

do_all_exchange(Index) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    AllExchanges = all_pairwise_exchanges(Index, Ring),
    LocalVN = {Index, node()},
    lists:map(
      fun(NextExchange) ->
              do_exchange(LocalVN, NextExchange, Ring),
              lager:info("===")
      end, AllExchanges),
    ok.

do_exchange(LocalVN, {RemoteIdx, IndexN}, Ring) ->
    Owner = riak_core_ring:index_owner(Ring, RemoteIdx),
    RemoteVN = {RemoteIdx, Owner},
    {ok, Fsm} = exchange_fsm:start_link(LocalVN, RemoteVN, IndexN),
    exchange_fsm:sync_start_exchange(Fsm),
    ok.

all_pairwise_exchanges(Index) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    all_pairwise_exchanges(Index, Ring).

all_pairwise_exchanges(Index, Ring) ->
    LocalIndexN = riak_kv_vnode:responsible_preflists(Index, Ring),
    Sibs = riak_kv_vnode:preflist_siblings(Index),
    lists:flatmap(
      fun(RemoteIdx) when RemoteIdx == Index ->
              [];
         (RemoteIdx) ->
              RemoteIndexN = riak_kv_vnode:responsible_preflists(Index, Ring),
              SharedIndexN = ordsets:intersection(ordsets:from_list(LocalIndexN),
                                                  ordsets:from_list(RemoteIndexN)),
              [{RemoteIdx, IndexN} || IndexN <- SharedIndexN]
      end, Sibs).

start_exchange(_, _, _, State) when State#state.exchanging /= undefined ->
    {already_exchanging, State};
start_exchange(LocalVN, {RemoteIdx, IndexN}, Ring, State) ->
    lager:info("Starting exchange: ~p", [LocalVN]),
    Owner = riak_core_ring:index_owner(Ring, RemoteIdx),
    RemoteVN = {RemoteIdx, Owner},
    case exchange_fsm:start(LocalVN, RemoteVN, IndexN) of
        {ok, FsmPid} ->
            Ref = monitor(process, FsmPid),
            State2 = State#state{exchanging=Ref},
            exchange_fsm:start_exchange(FsmPid),
            {ok, State2};
        {error, Reason} ->
            {Reason, State}
    end.

schedule_tick() ->
    Tick = ?TICK_TIME,
    timer:apply_after(Tick, gen_server, cast, [self(), tick]).

do_tick(State) ->
    State2 = maybe_build(State),
    %% State3 = maybe_exchange(State2),
    %% _X = Index,
    case State#state.index of
        0 ->
            State3 = maybe_reverify(State2);
        _ ->
            State3 = State2
    end,
    State3.

maybe_reverify(State) when State#state.exchanging /= undefined ->
    State;
maybe_reverify(State=#state{index=Index}) ->
    Pid = spawn(fun() ->
    case get_build_lock(Index) of
        {error, max_concurrency} ->
            ok;
        {ok, Lock} ->
            lager:info("Reverifying: ~p", [Index]),

    %% Tree = orddict:fetch(Id, Trees),
    %% Tree2 = hashtree:insert(Key, Hash, Tree),
    %% Trees2 = orddict:store(Id, Tree2, Trees),
    %% State#state{trees=Trees2}.

            Trees2 = orddict:map(fun({_,Tree}) ->
                                         hashtree:reverify(Index, Tree)
                                 end, State#state.trees),
            %% No way to update index_ht with these new Trees2
            %% Probably need to change things to not modify trees in reverify, but have
            %% reverify call do_insert, do_delete on index_ht instead
            lager:info("Finished reverifying: ~p", [Index]),
            release_lock(Index, Lock)
    end
    end),
    Ref = monitor(process, Pid),
    State#state{exchanging=Ref}.
            
maybe_build(State=#state{built=true}) ->
    State;
maybe_build(State=#state{index=Index}) ->
    case get_build_lock(Index) of
        {error, max_concurrency} ->
            State;
        {ok, Lock} ->
            lager:info("Starting build: ~p", [Index]),
            fold_keys(Index, self()),
            lager:info("Finished build: ~p", [Index]),
            release_lock(Index, Lock),
            State#state{built=true}
    end.

maybe_exchange(State=#state{index=Index}) ->
    %% TODO: Shouldn't always increment next-exchange on all failure cases
    %%       ie. max_concurrency
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    {NextExchange, State2} = next_exchange(Ring, State),
    LocalVN = {Index, node()},
    case start_exchange(LocalVN, NextExchange, Ring, State2) of
        {ok, State3} ->
            State3;
        {Reason, State3} ->
            lager:info("Exchange: ~p", [Reason]),
            State3
    end.
%% maybe_exchange(State=#state{index=Index}) ->
%%     case get_exchange_lock(Index) of
%%         {error, max_concurrency} ->
%%             State;
%%         {ok, Lock} ->
%%             {ok, Ring} = riak_core_ring_manager:get_my_ring(),
%%             {NextExchange, State2} = next_exchange(Ring, State),
%%             LocalVN = {Index, node()},
%%             do_exchange(LocalVN, NextExchange, Ring),
%%             release_lock(Index, Lock),
%%             State2
%%     end.

next_exchange(Ring, State=#state{exchange_queue=[]}) ->
    [Exchange|Rest] = all_pairwise_exchanges(State#state.index, Ring),
    State2 = State#state{exchange_queue=Rest},
    {Exchange, State2};
next_exchange(_Ring, State=#state{exchange_queue=Exchanges}) ->
    [Exchange|Rest] = Exchanges,
    State2 = State#state{exchange_queue=Rest},
    {Exchange, State2}.

%% Use global locks for concurrency limits.
%% TODO: Consider moving towards "exchange/index" manager approach
get_build_lock(Index) ->
    Concurrency = 20,
    get_lock(Index, build_token, Concurrency).

get_exchange_lock(Index) ->
    Concurrency = 1,
    get_lock(Index, concurrency_token, Concurrency).

get_lock(_LockId, _TokenId, 0) ->
    {error, max_concurrency};
get_lock(LockId, TokenId, Count) ->
    case global:set_lock({{TokenId, Count}, {node(), LockId}}, [node()], 0) of
        true ->
            {ok, {TokenId, Count}};
        false ->
            get_lock(LockId, TokenId, Count-1)
    end.

release_lock(LockId, Token) ->
    global:del_lock({Token, {node(), LockId}}, [node()]).
