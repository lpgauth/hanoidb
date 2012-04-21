%% ----------------------------------------------------------------------------
%%
%% hanoi: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(basho_bench_driver_hanoi).

-record(state, { tree,
                 filename,
                 flags,
                 sync_interval,
                 last_sync }).

-export([new/1,
         run/4]).

-include("hanoi.hrl").
-include_lib("basho_bench/include/basho_bench.hrl").

-record(btree_range, { from_key = <<>>       :: binary(),
                       from_inclusive = true :: boolean(),
                       to_key                :: binary() | undefined,
                       to_inclusive = false  :: boolean(),
                       limit :: pos_integer() | undefined }).

%% ====================================================================
%% API
%% ====================================================================

new(_Id) ->
    %% Make sure bitcask is available
    case code:which(hanoi) of
        non_existing ->
            ?FAIL_MSG("~s requires hanoi to be available on code path.\n",
                      [?MODULE]);
        _ ->
            ok
    end,

    %% Get the target directory
    Dir = basho_bench_config:get(hanoi_dir, "."),
    Filename = filename:join(Dir, "test.hanoi"),

    %% Look for sync interval config
    case basho_bench_config:get(hanoi_sync_interval, infinity) of
        Value when is_integer(Value) ->
            SyncInterval = Value;
        infinity ->
            SyncInterval = infinity
    end,

    %% Get any bitcask flags
    case hanoi:open(Filename) of
        {error, Reason} ->
            ?FAIL_MSG("Failed to open hanoi in ~s: ~p\n", [Filename, Reason]);
        {ok, FBTree} ->
            {ok, #state { tree = FBTree,
                          filename = Filename,
                          sync_interval = SyncInterval,
                          last_sync = os:timestamp() }}
    end.

run(get, KeyGen, _ValueGen, State) ->
    case hanoi:lookup(State#state.tree, KeyGen()) of
        {ok, _Value} ->
            {ok, State};
        not_found ->
            {ok, State};
        {error, Reason} ->
            {error, Reason}
    end;
run(put, KeyGen, ValueGen, State) ->
    case hanoi:put(State#state.tree, KeyGen(), ValueGen()) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason}
    end;
run(delete, KeyGen, _ValueGen, State) ->
    case hanoi:delete(State#state.tree, KeyGen()) of
        ok ->
            {ok, State};
        {error, Reason} ->
            {error, Reason}
    end;

run(fold_100, KeyGen, _ValueGen, State) ->
    [From,To] = lists:usort([KeyGen(), KeyGen()]),
    case hanoi:sync_fold_range(State#state.tree,
                                   fun(_Key,_Value,Count) ->
                                           Count+1
                                   end,
                                   0,
                                   #btree_range{ from_key=From,
                                                 to_key=To,
                                                 limit=100 }) of
        Count when Count >= 0; Count =< 100 ->
            {ok,State};
        Count ->
            {error, {bad_fold_count, Count}}
    end.