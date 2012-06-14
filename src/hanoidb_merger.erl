%% ----------------------------------------------------------------------------
%%
%% hanoidb: LSM-trees (Log-Structured Merge Trees) Indexed Storage
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

-module(hanoidb_merger).
-author('Kresten Krab Thorup <krab@trifork.com>').
-author('Gregory Burd <greg@burd.me>').

%%
%% Merging two BTrees
%%

-export([merge/6]).

-include("hanoidb.hrl").

%% A merger which is inactive for this long will sleep
%% which means that it will close open files, and compress
%% current ebloom.
%%
-define(HIBERNATE_TIMEOUT, 5000).

-define(COMPRESSION_METHOD, gzip).

%%
%% Most likely, there will be plenty of I/O being generated by
%% concurrent merges, so we default to running the entire merge
%% in one process.
%%
-define(LOCAL_WRITER, true).

merge(A,B,C, Size, IsLastLevel, Options) ->
    {ok, BT1} = hanoidb_reader:open(A, [sequential|Options]),
    {ok, BT2} = hanoidb_reader:open(B, [sequential|Options]),
    case ?LOCAL_WRITER of
        true ->
            {ok, Out} = hanoidb_writer:init([C, [{size,Size} | Options]]);
        false ->
            {ok, Out} = hanoidb_writer:open(C, [{size,Size} | Options])
    end,

    {node, AKVs} = hanoidb_reader:first_node(BT1),
    {node, BKVs} = hanoidb_reader:first_node(BT2),

    scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, {0, none}).

terminate(Out) ->

    case ?LOCAL_WRITER of
        true ->
            {ok, Count, _} = hanoidb_writer:handle_call(count, self(), Out),
            {stop, normal, ok, _} = hanoidb_writer:handle_call(close, self(), Out);
        false ->
            Count = hanoidb_writer:count(Out),
            ok = hanoidb_writer:close(Out)
    end,

    {ok, Count}.

step(S) ->
    step(S, 1).

step({N, From}, Steps) ->
    {N-Steps, From}.

hibernate_scan(Keep) ->
    erlang:garbage_collect(),
    receive
        {step, From, HowMany} ->
            {BT1, BT2, OutBin, IsLastLevel, AKVs, BKVs, N} = erlang:binary_to_term(hanoidb_util:uncompress(Keep)),
            scan(hanoidb_reader:deserialize(BT1),
                 hanoidb_reader:deserialize(BT2),
                 hanoidb_writer:deserialize(OutBin),
                 IsLastLevel, AKVs, BKVs, {N+HowMany, From})
    end.

scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, {N, FromPID}) when N < 1, AKVs =/= [], BKVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive
        {step, From, HowMany} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, {N+HowMany, From})
    after ?HIBERNATE_TIMEOUT ->
            case ?LOCAL_WRITER of
                true ->
                    Args = {hanoidb_reader:serialize(BT1),
                            hanoidb_reader:serialize(BT2),
                            hanoidb_writer:serialize(Out), IsLastLevel, AKVs, BKVs, N},
                    Keep = hanoidb_util:compress(?COMPRESSION_METHOD, erlang:term_to_binary(Args)),
                    hibernate_scan(Keep);
                false ->
                    scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, {0, none})
            end
    end;

scan(BT1, BT2, Out, IsLastLevel, [], BKVs, Step) ->
    case hanoidb_reader:next_node(BT1) of
        {node, AKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Step);
        end_of_data ->
            hanoidb_reader:close(BT1),
            scan_only(BT2, Out, IsLastLevel, BKVs, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, AKVs, [], Step) ->
    case hanoidb_reader:next_node(BT2) of
        {node, BKVs} ->
            scan(BT1, BT2, Out, IsLastLevel, AKVs, BKVs, Step);
        end_of_data ->
            hanoidb_reader:close(BT2),
            scan_only(BT1, Out, IsLastLevel, AKVs, Step)
    end;

scan(BT1, BT2, Out, IsLastLevel, [{Key1,Value1}|AT]=AKVs, [{Key2,Value2}|BT]=BKVs, Step) ->
    if Key1 < Key2 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoidb_writer:handle_cast({add, Key1, Value1}, Out);
                false ->
                    ok = hanoidb_writer:add(Out2=Out, Key1, Value1)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AT, BKVs, step(Step));

       Key2 < Key1 ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoidb_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = hanoidb_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AKVs, BT, step(Step));

       true ->
            case ?LOCAL_WRITER of
                true ->
                    {noreply, Out2} = hanoidb_writer:handle_cast({add, Key2, Value2}, Out);
                false ->
                    ok = hanoidb_writer:add(Out2=Out, Key2, Value2)
            end,
            scan(BT1, BT2, Out2, IsLastLevel, AT, BT, step(Step, 2))
    end.


hibernate_scan_only(Keep) ->
    erlang:garbage_collect(),
    receive
        {step, From, HowMany} ->
            {BT, OutBin, IsLastLevel, KVs, N} = erlang:binary_to_term(hanoidb_util:uncompress(Keep)),
            scan_only(hanoidb_reader:deserialize(BT),
                      hanoidb_writer:deserialize(OutBin),
                      IsLastLevel, KVs, {N+HowMany, From})
    end.


scan_only(BT, Out, IsLastLevel, KVs, {N, FromPID}) when N < 1, KVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive
        {step, From, HowMany} ->
            scan_only(BT, Out, IsLastLevel, KVs, {N+HowMany, From})
    after ?HIBERNATE_TIMEOUT ->
            Args = {hanoidb_reader:serialize(BT),
                    hanoidb_writer:serialize(Out), IsLastLevel, KVs, N},
            Keep = hanoidb_util:compress(?COMPRESSION_METHOD, erlang:term_to_binary(Args)),
            hibernate_scan_only(Keep)
    end;

scan_only(BT, Out, IsLastLevel, [], {_, FromPID}=Step) ->
    case hanoidb_reader:next_node(BT) of
        {node, KVs} ->
            scan_only(BT, Out, IsLastLevel, KVs, Step);
        end_of_data ->
            case FromPID of
                none ->
                    ok;
                {PID, Ref} ->
                    PID ! {Ref, step_done}
            end,
            hanoidb_reader:close(BT),
            terminate(Out)
    end;

scan_only(BT, Out, true, [{_,?TOMBSTONE}|Rest], Step) ->
    scan_only(BT, Out, true, Rest, step(Step));

scan_only(BT, Out, IsLastLevel, [{Key,Value}|Rest], Step) ->
    case ?LOCAL_WRITER of
        true ->
            {noreply, Out2} = hanoidb_writer:handle_cast({add, Key, Value}, Out);
        false ->
            ok = hanoidb_writer:add(Out2=Out, Key, Value)
    end,
    scan_only(BT, Out2, IsLastLevel, Rest, step(Step)).
