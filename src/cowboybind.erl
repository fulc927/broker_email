%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(cowboybind).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).

-record(state, {connection,channel,payload}).
-define(INTERVAL, 5000). % One minute

start_link({VHost, Queue}, Domain) ->
    gen_server:start_link(?MODULE, [{VHost, Queue}, Domain], []).

init([{VHost, Queue}, Domain]) ->
    process_flag(trap_exit, true),
    erlang:send_after(?INTERVAL, self(), trigger),
    {ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
   {ok, Connection} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = <<"/">>, host = Host, port = Port}),
    %{ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host=VHost}),
    try_declaring_queue(Connection, Queue),

    {ok, Channel} = amqp_connection:open_channel(Connection),
    Binding = #'queue.bind'{queue   = Queue,
                            exchange    = <<"pipe_cowboy">>,
                            routing_key = <<"rk">>},
                #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    Subscribe = #'basic.consume'{queue=Queue, consumer_tag=Domain, no_ack=true},
    #'basic.consume_ok'{} = amqp_channel:call(Channel, Subscribe),

    State = #state{connection=Connection, channel=Channel},
    {ok, State}.

try_declaring_queue(Connection, Queue) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    try
        catch amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true})
    after
        catch amqp_channel:close(Channel)
    end.


handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% This is the first message received
handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};

%% This is received when the subscription is cancelled
handle_info(#'basic.cancel_ok'{}, State) ->
    {noreply, State};

%% A delivery
handle_info({#'basic.deliver'{routing_key=Key, consumer_tag=Tag}, Content}, State) ->
    #amqp_msg{props = Properties, payload = Payload} = Content,
    #'P_basic'{message_id = MessageId, headers = Headers} = Properties,

    rabbit_log:info("GOT A DELIVERY FROM COWBOY !!! ~p ~n",[Payload]),

    %PARTIE CERTAINEMENT INEFFECTIVE A SOUHAIT A VOIR PLUS TARD...
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host= <<"/">>}),
    {ok, Channel} = amqp_connection:open_channel(Connection),

    Binding = #'queue.bind'{queue       = <<"incoming_mailtesting">>,
			    exchange    = <<"email-in">>,
			    routing_key = Payload},
    try
        catch #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding) 
    after
           catch amqp_channel:close(Channel)
    end,
   
    %%SEB TIMEOUT
    rabbit_log:info("GOT A INSERT FROM COWBOY !!! ~p ~n",[Payload]),
     gen_server:cast(store_and_dispatch, {insert,Payload}),
     timer:sleep(60000),
    rabbit_log:info("COWBOY TIMEOUT au bout de 60s ~n"),
     gen_server:cast(store_and_dispatch, {delete,Payload}),
   %SEB

    %ok = amqp_channel:close(Channel),
    %ok = amqp_connection:close(Connection),
    %PARTIE INEFFECTIVE

    %Payload pourrait etre utilise pour unbind les queue au fur et a mesure quon les attache detache
    %pour cela il faut envisager un autre handle_info comme https://stackoverflow.com/questions/5883741/how-to-perform-actions-periodically-with-erlangs-gen-server
    NewState = State#state{payload = Payload},
    {noreply, NewState};


handle_info(Msg, State) ->
    rabbit_log:info("~w", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{connection=Connection, channel=Channel}) ->
	amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% end of file

