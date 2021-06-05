%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(broker_message_sender).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,terminate/2, code_change/3]).

-record(state, {connection, channel, exchange}).

start_link(Domain) ->
    gen_server:start_link(?MODULE, [Domain], []).

init([Domain]) ->
	rabbit_log:info("MESSAGE_SENDER_Domain ~p ~n",[Domain]),
    {ok, Domains} = application:get_env(broker_email, email_domains),
	rabbit_log:info("MESSAGE_SENDER_DomainS ~p ~n",[Domains]),
    {VHost, Exchange} = {<<"/">>,<<"email-in">>},

    process_flag(trap_exit, true),
    {ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host=VHost}),
   % {ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
   % {ok, Connection} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = VHost, host = Host, port = Port}),
    try_declaring_exchange(Connection, Exchange),  %l'exchange en question est email-in

    {ok, Channel} = amqp_connection:open_channel(Connection),
	rabbit_log:info("MESSAGE_SENDER_init Connection ~p ~n",[Connection]),
	rabbit_log:info("MESSAGE_SENDER_init channel1 ~p ~n",[Channel]),
    State = #state{connection=Connection, channel=Channel, exchange=Exchange},
    {ok, State}.

try_declaring_exchange(Connection, Exchange) ->
    {ok, Channel} = amqp_connection:open_channel(Connection),
    try
        catch amqp_channel:call(Channel, #'exchange.declare'{exchange=Exchange,durable=true,type = <<"topic">>})
    after
        catch amqp_channel:close(Channel)
    end.

handle_call(_Msg, _From, State) ->
    {reply, unknown_command, State}.

handle_cast({Reference, To, ContentType, Headers, Body, _From}, #state{channel=Channel, exchange=Exchange}=State) ->
    rabbit_log:info(" SENDERHEADERS ~p ~n", [Headers]),
    rabbit_log:info(" SENDERchannel2 ~p ~n", [Channel]),
    lists:foreach(
        fun(Address) ->
            Publish = #'basic.publish'{exchange=Exchange, routing_key=Address},
            Properties = #'P_basic'{delivery_mode = 2, %% persistent message
                content_type = set_content_type(ContentType),
                message_id = list_to_binary(Reference),
                timestamp = amqp_ts(),
                headers = lists:map(fun({Name, Value}) -> {Name, longstr, Value} end, Headers)},
                %HEADER spcifique que javais mis la pour consumer une queue qui envoie des emails  headers = [{<<"From">>, longstr, From}]},
            Msg = #amqp_msg{props=Properties, payload=Body},
            amqp_channel:cast(Channel, Publish, Msg) end, To),
    	            {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State}.

handle_info(_Msg, State) ->
    %rabbit_log:info("~w", [Msg]),
    {noreply, State}.

terminate(_Reason, #state{connection=Connection, channel=Channel}) ->
    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

set_content_type(<<>>) -> undefined;
set_content_type(ContentType) -> ContentType.

amqp_ts() ->
    {MegaSecs, Secs, _MicroSecs} = erlang:timestamp(),
    MegaSecs * 1000 * 1000 + Secs.

% end of file

