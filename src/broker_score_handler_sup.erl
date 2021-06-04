%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(broker_score_handler_sup).
-behaviour(supervisor).

-include_lib("amqp_client/include/amqp_client.hrl").
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link(?MODULE, _Arg = []).

init([]) ->

    {ok, {{one_for_one, 3, 10}, child_spec()}}.

child_spec() ->
    {ok, Queues} = application:get_env(broker_email, incoming_mailtesting),
    lists:map(fun({{VHost, Queue}, Domain, Rkey}) -> 
	{list_to_atom("message_incoming"++binary_to_list(Domain)),
	{broker_score_handler, start_link, [{VHost, Queue}, Domain,Rkey]},
	permanent,
       	10000, 
	worker,
       	[broker_score_handler]} 
     end, Queues).
% end of file

