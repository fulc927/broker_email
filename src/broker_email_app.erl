%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(broker_email_app).

-behaviour(application).
-export([start/2, stop/1]).

-behaviour(supervisor).
-export([init/1]).

start(normal, []) ->
    supervisor:start_link(?MODULE, _Arg = []).
    
stop(_State) ->
    ok.

init([]) ->
    %ETS initialization
   %?MODULE = ets:new(?MODULE, [named_table, ordered_set, public]),
   DB =  ets:new(broker_email_app, [named_table, ordered_set, public]),
   rabbit_log:info("BROKER_EMAIL_APP ~p ~n",[DB]), 
    % check for optional dependencies
    case erlang:function_exported(eiconv, conv, 2) of
        true -> rabbit_log:info("eiconv detected: content trancoding is enabled");
        false -> rabbit_log:warning("eiconv not detected: content transcoding is DISABLED")
    end,
    {ok, ServerConfig} = application:get_env(broker_email, server_config),
    {ok, {{one_for_one, 3, 10},
        % email to amqp
        [
	{email_handler, {gen_smtp_server, start_link, [broker_email_handler, ServerConfig]},permanent, 10000, worker, [broker_email_handler]},
	%{email_handler, {gen_smtp_server, start_link, [broker_email_handler, ServerConfig,[{keyfile, "test/fixtures/server.key"}, {certfile, "test/fixtures/server.crt"}, {hostname, "localhost"}]]},permanent, 10000, worker, [broker_email_handler]},
	{broker_score_handler_sup, {broker_score_handler_sup, start_link, []},permanent, 10000, supervisor, [broker_score_handler_sup]},
	{result_queue, 
	        {result_queue,start_link, [{<<"/">>,<<"SCORE_EVERY_BOX">>},<<"mail-testing.com">>,[<<"seb@mail-testing.com">>]]}, 
	 	permanent, 
	 	10000, 
	 	worker, 
	 	[result_queue]},
	{result_queue_push, 
	        {result_queue,start_link, [{<<"/">>,<<"PUSH_EVERY_BOX">>},<<"mail-testing.com">>,[<<"seb@mail-testing.com">>]]}, 
	 	permanent, 
	 	10000, 
	 	worker, 
	 	[result_queue]},
	  #{id => store_and_dispatch,
             start =>  {store_and_dispatch, start_link, []},
             restart =>  permanent,
            shutdown => 10000,
           type =>  worker,
           module => [store_and_dispatch]},	   
{cowboyBIND, 
	 	{cowboybind,start_link, [{<<"/">>,<<"cowboybind">>},<<"mail-testing.com">>]}, 
	 	permanent, 
	 	10000, 
	 	worker, 
	 	[cowboybind]}
	]}}.
