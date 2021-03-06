%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Utility module.
-module(nkdocker_util).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([remove_exited/0, remove_exited/1, build/3]).
-export([make_tar/1]).

%% ===================================================================
%% Public
%% ===================================================================

%% @doc Removes all exited containers
-spec remove_exited() ->
	ok | {error, term()}.

remove_exited() ->
	remove_exited(#{}).


%% @doc Removes all exited containers
-spec remove_exited(nkdocker:conn_opts()) ->
	ok | {error, term()}.

remove_exited(Opts) ->
	Op = fun(Pid) ->
		case nkdocker:ps(Pid, #{filters=>#{status=>[exited]}}) of
			{ok, List} ->
				Ids = [Id || #{<<"Id">>:=Id} <- List],
				remove_exited(Pid, Ids);
			{error, Error} ->
				{error, Error}
		end
	end,
	docker(Opts, Op).


%% @doc 
-spec build(pid(), string()|binary(), binary()) ->
	ok | {error, term()}.

build(Pid, Tag, TarBin) ->
	case nkdocker:inspect_image(Pid, Tag) of
    	{ok, _} ->
    		ok;
		{error, {not_found, _}} ->
			lager:notice("Building docker image ~s", [Tag]),
    		case nkdocker:build(Pid, TarBin, #{t=>Tag, async=>true}) of
    			{async, Ref} ->
    				case wait_async(Pid, Ref) of
    					ok ->
    						case nkdocker:inspect_image(Pid, Tag) of
    							{ok, _} -> ok;
    							_ -> {error, image_not_built}
    						end;
    					{error, Error} ->
    						{error, Error}
    				end;
    			{error, Error} ->
    				{error, {build_error, Error}}
    		end;
    	{error, Error} ->
    		{error, {inspect_error, Error}}
    end.


make_tar(List) ->
	list_to_binary([nkdocker_tar:add(Path, Bin) || {Path, Bin} <- List]).






%% ===================================================================
%% Private
%% ===================================================================


%% @private
docker(Opts, Fun) ->
	case nkdocker:start_link(Opts) of
		{ok, Pid} ->
			Res = Fun(Pid),
			nkdocker:stop(Pid),
			Res;
		{error, Error} ->
			{error, Error}
	end.


%% @private
remove_exited(_Pid, []) ->
	ok;

remove_exited(Pid, [Id|Rest]) ->
	case nkdocker:rm(Pid, Id) of
		ok -> 
			lager:info("Removed ~s", [Id]);
		{error, Error} ->
			lager:notice("NOT Removed ~s: ~p", [Id, Error])
	end,
	remove_exited(Pid, Rest).


%% @private
wait_async(Pid, Ref) ->
	Mon = monitor(process, Pid),
	Result = wait_async_iter(Ref, Mon),
	demonitor(Mon),
	Result.


wait_async_iter(Ref, Mon) ->
	receive
		{nkdocker, Ref, {data, #{<<"stream">> := Text}}} ->
			io:format("~s", [Text]),
			wait_async_iter(Ref, Mon);
		{nkdocker, Ref, {data, #{<<"status">> := Text}}} ->
			io:format("~s", [Text]),
			wait_async_iter(Ref, Mon);
		{nkdocker, Ref, {data, Data}} ->
			io:format("~p\n", [Data]),
			wait_async_iter(Ref, Mon);
		{nkdocker, Ref, {ok, _}} ->
			ok;
		{nkdocker, Ref, {error, Reason}} ->
			{error, Reason};
		{nkdocker, Ref, Other} ->
			lager:warning("Unexpected msg: ~p", [Other]),
			wait_async_iter(Ref, Mon);
		{'DOWN', Mon, process, _Pid, _Reason} ->
			{error, process_failed}
	after 
		180000 ->
			{error, timeout}
	end.
