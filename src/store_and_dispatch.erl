-module(store_and_dispatch).
-behaviour(gen_server).

-export([start/0, start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2, stop/0, terminate/2]).
-export([code_change/3]).

start_link() ->
  gen_server:start_link({local, store_and_dispatch}, store_and_dispatch, [], []).

start() ->
  gen_server:start({local, store_and_dispatch}, store_and_dispatch, [], []).

init([]) ->
 %WHITELISTER UNE ADRESSE PERSO
 ets:insert(broker_email_app, {<<"admin@mail-testing.com">>}),
 State  = [],
  {ok, State}.

handle_cast({insert,Target},State) ->
        Alors = ets:insert(broker_email_app, {Target}),
        rabbit_log:info("STORE_AND_DISPATCH insert Target et true/false  ~p ~p ~n",[Target,Alors]),
  {noreply, State};
handle_cast({delete,Target},State) ->
        ets:delete(broker_email_app,Target),
        Look_after_del = ets:lookup(broker_email_app, Target),
        rabbit_log:info("STORE_AND_DISPATCH delete Look_after_del  ~p ~n",[Look_after_del]),
  {noreply, State}.

handle_call({query,Target}, _From, State) ->
        rabbit_log:info("store_and_dispatch query Target ~p ~n",[Target]),
        Reply = ets:lookup(broker_email_app, Target),
        rabbit_log:info("store_and_dispatch Reply ~p ~n",[Reply]),
{reply, Reply, State}.

handle_info(_Msg, LoopData) ->
  {noreply, LoopData}.

stop() -> gen_server:cast(store_and_dispatch, stop).

terminate(_Reason, _LoopData) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
