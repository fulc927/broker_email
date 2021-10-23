%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
-module(outgoing_email).
-behaviour(gen_server).

-include_lib("amqp_client/include/amqp_client.hrl").

-export([start_link/3]).
-export([send_email/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
    terminate/2, code_change/3]).
-record(state, {connection, channel}).

start_link({VHost, Queue}, Domain, Rkey) ->
    gen_server:start_link(?MODULE, [{VHost, Queue}, Domain, Rkey], []).

init([{VHost, Queue}, Domain, Rkey]) ->
	%process_flag(trap_exit, true),
	%{ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
	%io:format("broker_email Username ~p ~n",[Username]),
	{ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host= VHost}),
    	%{ok, Connection} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = <<"/">>, host = Host, port = Port}),
	pick_the_rk(Connection, Queue, Rkey).
    	pick_the_rk(Connection, Queue, [H|T]) ->
           {ok, Channel} = amqp_connection:open_channel(Connection),
           %amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true,auto_delete=false}),
           amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true, auto_delete=false}),
                Binding = #'queue.bind'{queue   = Queue,
                            exchange    = <<"email-out">>,
                            routing_key = H},
                #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    	pick_the_rk(Connection, Queue, T);
    	pick_the_rk(Connection, Queue,[]) -> 
				     {ok, Channel} = amqp_connection:open_channel(Connection),
                                     Subscribe = #'basic.consume'{queue=Queue, consumer_tag= <<"mail-testing.com">>, no_ack=true},
                                     #'basic.consume_ok'{} = amqp_channel:call(Channel, Subscribe),
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
        #amqp_msg{props = Properties, payload = Payload} = Content,
	%send_email(To, Domain, {Type, Subtype}, Headers, Payload) ->
        {ok, Rcpt} = application:get_env(broker_email, rcpt),
	rabbit_log:info("Pour l instant et vu qu on a pas de consumer rien a PATTERN MATCHER ~p ~n",[Payload]),
	broker_email2_sender:send_email(Rcpt,<<"opentelecom.fr">>,{<<"text">>,<<"plain">>},[{<<"Subject">>,<<"test sujet">>}],Payload),
	{noreply, State};

%-module(broker_email2_sender).
%-export([send_email/5]).
%send_email(To, Domain, {Type, Subtype}, Headers, Payload) ->

%% This is received when the subscription is cancelled
handle_info(#'basic.cancel_ok'{}, State) ->
    {noreply, State}.

send_email(To, Domain, {Type, Subtype}, Headers, Payload) ->
    ToAddr = construct_address(To, Domain),
    rabbit_log:info("sending ~p/~p e-mail to ~p~n", [Type, Subtype, ToAddr]),
    % add correct From and To headers
    {ok, From} = application:get_env(broker_email, email_from),
    %Headers2 = Headers ++ [{<<"From">>, construct_address(From, Domain)},{<<"To">>, ToAddr}],
    Headers2 = Headers ++ [{<<"From">>, construct_address(From, <<"mail-testing.com">>)},{<<"To">>, ToAddr}],

    Message = mimemail:encode({Type, Subtype,lists:foldr(fun set_header/2, [], Headers2), [], Payload}),

    % client_sender must be a valid user, whereas From doesn't have to
    {ok, Sender} = application:get_env(broker_email, client_sender),
    {ok, ClientConfig} = application:get_env(broker_email, client_config),
    case gen_smtp_client:send({Sender, [ToAddr], Message}, ClientConfig) of
	{ok, _Pid} -> ok;
	{error, Res} -> rabbit_log:error("message cannot be sent: ~w~n", [Res])
    end.

set_header({Name, Binary}, Acc) when is_binary(Binary) -> [{Name, Binary}|Acc];
set_header({Name, List}, Acc) when is_list(List) -> [{Name, list_to_binary(List)}|Acc];
set_header({_Name, undefined}, Acc) -> Acc;
set_header({_Name, <<>>}, Acc) -> Acc;
set_header({_Name, []}, Acc) -> Acc.

construct_address(Addr, Domain) ->
    case binary:match(Addr, <<"@">>) of
        nomatch -> <<Addr/binary, $@, Domain/binary>>;
        _Else -> Addr
    end.

% end of file



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
