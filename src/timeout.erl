-module(timeout).
-behaviour(gen_server).

-export([start/0, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([code_change/3]).

start() ->
  gen_server:start_link({local, timeout}, timeout, [], []).

init([]) ->
  {ok, []}.

handle_cast({timeo,Target},State) ->
    	timer:sleep(60000),
        ets:delete(broker_email_app,Target),
        Look_after_del = ets:lookup(broker_email_app, Target),
        rabbit_log:info("TIMEOUT De quel Target on parle qui a été effacé Look_after_del ~p  ~p ~n",[Target,Look_after_del]),
  {noreply, State}.

handle_call(_Msg,_From, State) ->
{reply, unknown_command, State}.

handle_info(_Msg, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
