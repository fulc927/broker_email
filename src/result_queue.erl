%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
-module(result_queue).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).
-record(state, {connection, channel}).

start_link({VHost, Queue}, Domain, Rkey) ->
    gen_server:start_link(?MODULE, [{VHost, Queue}, Domain, Rkey], []).

init([{VHost, Queue}, Domain, Rkey]) ->
	process_flag(trap_exit, true),
	{ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
	io:format("broker_email Username ~p ~n",[Username]),
    	{ok, Connection} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = <<"/">>, host = Host, port = Port}),

	pick_the_rk(Connection, Queue, Rkey).
    	pick_the_rk(Connection, Queue, [H|T]) ->
           {ok, Channel} = amqp_connection:open_channel(Connection),
           %amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true,auto_delete=false}),
           amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true, auto_delete=false}),
                Binding = #'queue.bind'{queue   = Queue,
                            exchange    = <<"pipe_results">>,
                            routing_key = H},
                #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    	pick_the_rk(Connection, Queue, T);
    	pick_the_rk(Connection, Queue,[]) -> 
				     {ok, Channel} = amqp_connection:open_channel(Connection),
                                     %Subscribe = #'basic.consume'{queue=Queue, consumer_tag= <<"mail-testing.com">>, no_ack=true},
                                     %#'basic.consume_ok'{} = amqp_channel:call(Channel, Subscribe),
				     %{ok, State}.
					State = #state{connection=Connection, channel=Channel},
    					{ok, State}.





handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% This is the first message received
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

handle_info({#'basic.deliver'{routing_key=RKey, consumer_tag=_Tag}, Content}, State) ->
	rabbit_log:info("Pour l instant et vu qu on a pas de consumer rien a PATTERN MATCHER"),
    {noreply, State};

%% This is received when the subscription is cancelled
handle_info(#'basic.cancel_ok'{}, State) ->
    {noreply, State}.
terminate(_Reason, _State) ->
ok.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
{ok, State}.
