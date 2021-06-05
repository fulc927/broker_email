%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
-module(broker_score_handler).
-behaviour(gen_server).

-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([process_results/6, tothefront/3, tothefront2/4]).
-record(state, {connection, channel,routing_key,id,serveur,ip,table}).
-define(FILENAME,"SEBFILE").
-define(FILENAME2,"SEBFILE2").
-include_lib("amqp_client/include/amqp_client.hrl").

start_link({VHost, Queue}, Domain, Rkey) ->
    gen_server:start_link(?MODULE, [{VHost, Queue}, Domain, Rkey], []).

init([{VHost, Queue}, _Domain, Rkey]) ->
    process_flag(trap_exit, true),
    %{ok, Connection} = amqp_connection:start(#amqp_params_direct{virtual_host=VHost}),
    {ok,_Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
    {ok, Connection} = amqp_connection:start(#amqp_params_network{username =Username, password = Password,virtual_host = VHost, host = Host, port = Port}),


    pick_the_rk(Connection, Queue, Rkey).
    pick_the_rk(Connection, Queue, [H|T]) ->
    rabbit_log:info("RABBIT_SCORE_PERSO TAILRECURSION ~p ", [H]),
           {ok, Channel} = amqp_connection:open_channel(Connection),
           %amqp_channel:call(Channel, #'queue.declare'{queue=Queue, durable=true,auto_delete=false}),
           amqp_channel:call(Channel, #'queue.declare'{queue=Queue, auto_delete=false}),
                Binding = #'queue.bind'{queue   = Queue,
                            exchange    = <<"email-in">>,
                            %routing_key = <<"seb@otp.fr.eu.org">>},
                            routing_key = H},
                #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    pick_the_rk(Connection, Queue, T);
    pick_the_rk(Connection, Queue,[]) -> {ok, Channel} = amqp_connection:open_channel(Connection),
                                     Subscribe = #'basic.consume'{queue=Queue, consumer_tag= <<"otp.fr.eu.org">>, no_ack=true},
                                     #'basic.consume_ok'{} = amqp_channel:call(Channel, Subscribe),
				     Routing_key="",
				     Id="",
                                     State = #state{connection=Connection, channel=Channel,routing_key=Routing_key, id=Id},
				     {ok, State}.

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
handle_info({#'basic.deliver'{routing_key=RKey, consumer_tag=_Tag}, Content}, State) ->
    #amqp_msg{props = Properties, payload = Payload} = Content,
	Reference2 = lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(term_to_binary(os:timestamp()))]),
	case application:get_env(broker_email, email_store) of
	undefined -> ok;
	{ok, Dir} -> file:write_file(Dir++"email/new/mail-"++Reference2++".txt", Payload),
	%{ok, Dir} -> file:write_file(Dir++"/mail-"++Reference2++".txt", Payload),
%        rabbit_log:info("EMAIL_HANDLER_TRY Hostname et Address ~s ~s ~n", [_Hostname, _Address]),
%        rabbit_log:error("le Dir ~p ~n", [Dir]),
        rabbit_log:error("PERSO reference2 ~p ~n", [Reference2])
    	end,
	
    #'P_basic'{message_id = _MessageId, headers = Headers } = Properties,
    %{Type, Subtype} = get_content_type(Properties#'P_basic'.content_type),
    rabbit_log:info("RABBIT_SCORE_PERSO to SPAMASSASSIN ~p" , [Payload]),
    rabbit_log:info("RABBIT_SCORE_PERSO messageid ~p" , [_MessageId]),
    %rabbit_log:info("RABBIT_SCORE_PERSO Headers ~p" , [Headers]),
    %rabbit_log:info("RABBIT_SCORE_PERSO Date ~p" , [#Headers.date]),
    Headers2 = transform_headers(Headers),
    rabbit_log:info("RABBIT_SCORE_PERSO Headers2 ~s ~n ", [Headers2]),
    Date = proplists:get_value(<<"Date">>,Headers2),
    De = proplists:get_value(<<"From">>,Headers2),
    Ip = proplists:get_value(<<"Ip">>,Headers),
    Hst = proplists:get_value(<<"Serveur">>,Headers2),
    rabbit_log:info("RABBIT_SCORE_PERSO Date ~s ~n ", [Date]),
    calcule_score(RKey, Payload),

    Table = ets:new(?MODULE, [set, public]),
		%ets:insert(Table,{Reference2,{<<"de">>,longstr,De},{<<"routing_key">>,longstr,RKey},{<<"date">>,longstr,Date},{<<"dkim_valid">>,longstr,0},{<<"spf_pass">>,longstr,0},{<<"ipv6">>,longstr,0}}), %$3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
		ets:insert(Table,{Reference2,<<"de">>,longstr,De,<<"routing_key">>,longstr,RKey,<<"date">>,longstr,Date,<<"dkim_valid">>,signedint,0,<<"spf_pass">>,signedint,0,<<"ipv6">>,signedint,0}), %$3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
              %PW = ets:match(Table,{Reference2,'$1','$2','$3','$4','$5','$6','$7','$8','$9','$10','$11','$12'}), %$1-2 de $3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
	   %rabbit_log:info("PATTERN ds la BASE ~p ~n",[PW]),
    
    rabbit_log:info("RABBIT_SCORE_PERSO serveur Hst ~n ", [Hst]),
    rabbit_log:info("RABBIT_SCORE_PERSO ip ~s ~n ", [Ip]),
    NewState = State#state{routing_key= RKey, id= Reference2,serveur=Hst,ip=Ip,table=Table},
    {noreply,  NewState };

%%On choppe la réponse de SA
handle_info(Msg, State) ->
    case Msg of
        {_,_,Data} ->
	   rabbit_log:info("XXX RABBIT_SCORE_PERSO retour de SPAMASSASSIN (c'est un binary string) ~p" , [Data]),
	   RKey = State#state.routing_key,
	   rabbit_log:info("XXX RABBIT_SCORE_PERSO retour le routing key ~p" , [RKey]),
	   Id = State#state.id,
	   _Ip = State#state.ip,
	   _Serveur = State#state.serveur,
	   %Head = State#state.head,
	   rabbit_log:info("RABBIT_SCORE_PERSO retour SPAMASSASSIN ~p" , [Data]),
	   parse(Id,State,RKey,Data);
        {_,_} ->
	   rabbit_log:alert("RABBIT_SCORE_PERSOfrom tcpclosing ~p ~n" , [Msg])		    
    end,
	rabbit_log:info("plus de messages from rabbit_score_handler ~p" , [Msg]),
        {noreply, State}.

transform_headers(undefined) ->
    [];
transform_headers(Headers) ->
    lists:map(fun
        ({Name, longstr, Value}) -> {Name, Value}
            %end, undefined, List)}
    end, Headers).
calcule_score(_Key,Payload) ->
    Message = binary_to_list(Payload),
    HdrContent = ["Content-length: ", num(Message)+1,"\r\n" ],
    HdrContent2 = lists:concat(HdrContent),
    Message2 = Message ++ "\n",
    client(HdrContent2,Message2).

client(HdrContent2,Message2) ->
    case gen_tcp:connect("127.0.0.1", 783, [{mode, binary}]) of
        {ok, Sock} ->
            gen_tcp:send(Sock, "HEADERS SPAMC/1.5\r\n"),
            gen_tcp:send(Sock, "User: debian-spamd\r\n"),
            gen_tcp:send(Sock, HdrContent2),
            gen_tcp:send(Sock, "\r\n"),
            gen_tcp:send(Sock, Message2);
        {error,_} ->
            io:fwrite("Connection error! Quitting...~n")
    end.

num([]) -> 0;
num([_|L])  -> num(L) + 1.

append([H|T], Tail) ->
    		[lists:concat([H,"\r\n"])|append(T, Tail)];
		append([], Tail) ->
    		Tail.
%decode first line of input using line decoder
parse(Id,State,_RKey,Data) ->
                {ok, Line, Rest} = erlang:decode_packet(line, Data, []),
                rabbit_log:info("PARSE SCORE_HANDLER le retour de SA ~s" , [Data]),
                parse(Id,State,_RKey,Line, Rest).
                %parse(<<"auie@auie">>,Line, Rest).
           %match SPAMD of initial prefix
           parse(Id,State,_RKey,<<"SPAMD/", _/binary>>, Data) ->
                parse(Id,State,_RKey,Data, []);
           parse(Id,State,_RKey,<<>>, Hdrs) ->
           %check when input data is exhausted, on accumule la liste des headers et on la passe a la fonction process_resluts
                Result = [{Key,Value} || {http_header, _, Key, _, Value} <- Hdrs],
                Map=maps:from_list(Result),
                %map on decode les data avec httph docedore en acculmulant chaque header en ignorant les http_eoh
                XSpamStatus = maps:get("X-Spam-Status", Map, "Default value"),
                Score = string:lexemes(XSpamStatus, " ,\r\n\t=")++"  ",
		Score2 = append(Score,[]),
                rabbit_log:info("Score2 ~p ~n" , [Score2]),
                rabbit_log:info("XSpamStatus ~p ~n" , [XSpamStatus]),

		%retour Score ==  2021-04-17 23:11:38.291 [info] <0.917.0> PARSE SCORE_HANDLER every tests SA ["Yes","score","5.4","required","-5.0","tests","DATE_IN_FUTURE_96_Q","\r\n","EMPTY_MESSAGE","HTML_MESSAGE","MISSING_SUBJECT","RDNS_NONE\r\n","autolearn","disabled","version","3.4.2"]
  		%case dets:open_file(spamassassin_table, [{file, ?FILENAME2},{type,set}]) of
   		%	{ok, Ref} -> dets:insert(spamassassin_table,{Id,Score}),
            	%	io:format("display le Score ~p ~p" , [Id,Score]);
   		%	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E])end,
		
                Sa = list_to_binary(sascore2(2,Score)),
                rabbit_log:info("PARSE SCORE_HANDLER every tests SA ~p" , [Sa]),
                %Sa_amqp = <<"<P class=\"blocktext\">Voici la note Spamassassin: ",Sa/binary," /10 </P>">>,
                process_results(Id,State,_RKey,string:lexemes(XSpamStatus, " ,\r\n\t="),Score2,[]);

           parse(Id,State,_RKey,Data, Hdrs) ->
                case erlang:decode_packet(httph, Data, []) of
                    {ok, http_eoh, Rest} ->
                        parse(Id,State,_RKey,Rest, Hdrs);
                    {ok, Hdr, Rest} ->
                        parse(Id,State,_RKey,Rest, [Hdr|Hdrs]);
                    Error ->
                        Error
                end.

           %sascore(N,List) when N > 0 ->
        %       Score = [List | Score],
        %       N = N - 1,
        %       sascore2(N - 1, Score);
        %   sascore(N,Score) ->
            %    rabbit_log:info("PARSE SCORE_HANDLER le retour de SA ~p" , [Data]).

           sascore2(N,[_W|U]) when N > 0 ->
           sascore2(N-1,U);
           sascore2(_N,[W|_U]) -> W.

           process_results(_Id,_State,_RKey,[],_Draft_Score,[]) ->
              {error, not_found};
	   
	   process_results(Id,State,_RKey,[],Draft_Score, Results) ->
           %_Date= [Ac || {<<"Date", _/binary>>,Ac} <- _Head],
           %rabbit_log:info("PARSE SCORE_HANDLER CHOPPE LE FINAL _RESULTS ~p" , [Results]),
           %rabbit_log:info("PARSE SCORE_HADLER _DATE ~p" , [_Date]),
	   tothefront(Id,_RKey,[list_to_binary(Draft_Score)|Results]),
	   _Tab = State#state.table,
	   %tothefront2(State,Tab,Id,_RKey),
               {ok, lists:reverse(Results)};
                       	   
	   process_results(Id,State,_RKey,[V="SPF_PASS"|T],Draft_Score,Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
	   %case ets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
	   %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   Tab = State#state.table,
   	   ets:update_counter(Tab,Id,{16,1}),
%	{ok, Ref} -> ets:update_counter(?MODULE,Id,{11,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
           rabbit_log:info("CHOPPE LE SPF_PASS VALID ~p" , [Results]);

	   process_results(Id,State,_RKey,[V="SPF_PASS\r\n"|T],Draft_Score,Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
	   %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   Tab = State#state.table,
   	   ets:update_counter(Tab,Id,{16,1}),
%	{ok, Ref} -> ets:update_counter(?MODULE,Id,{11,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
           rabbit_log:info("CHOPPE LE SPF_PASS\r\n VALID ~p" , [Results]);

	   process_results(Id,State,_RKey,[V="DKIM_VALID"|T],Draft_Score, Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
           %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
	   Tab = State#state.table,
   	   ets:update_counter(Tab,Id,{13,1}),
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
	   rabbit_log:info("CHOPPE LE Table ~p" , [Tab]),
	   rabbit_log:info("CHOPPE LE Table ~p" , [ets:lookup(Tab, Id)]),
	   rabbit_log:info("CHOPPE LE DKIM_VALID ~p" , [Results]);
	   
	   	   
	   %process_results(Id,_RKey,[V="SPF_NONE"|T],Draft_Score, Results) ->
           %process_results(Id,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
           %case dets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   %	{ok, Ref} -> dets:update_counter(?MODULE,Id,{11,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
	   %rabbit_log:info("PARSE SCORE_HANDLER CHOPPE LE RESULTS SPF_NONE ~p" , [Results]);

           %process_results(Id,_RKey,[V="SPF_FAIL"|T],Draft_Score,Results) ->
           %process_results(Id,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
           %case dets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   %	{ok, Ref} -> dets:update_counter(?MODULE,Id,{15,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,

           %process_results(Id,_RKey,[V="HTML_MESSAGE"|T],Draft_Score, Results) ->
           %process_results(Id,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
           %case dets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   %	{ok, Ref} -> dets:update_counter(?MODULE,Id,{17,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
	   %%process_results(_RKey,T, [list_to_binary("<P class=\"blocktext\">"++V++"</P>")|Results]);
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

 	   %process_results(,_RKey,[V="DKIM_SIGNED"|T], Results) ->
           %_String = [{<<"dkim-signature">>,<<"from [192.168.56.19] (unknown [78.244.12.182]) (Envelope-From XXXXXXX@YYYYYYY)(Authenticated sender: YYYYYY@UUUUUUU)by smtp4-g21.free.fr (Postfix) with ESMTPSA id 345EA19F4F8for <ifFUWlUa9N@IIIIIII.FR>; Thu, 21 May 2020 23:58:14 +0200 (CEST)">>},{<<"Date">>,<<"Thu, 21 May 2020 23:58:13 +0200">>},{<<"charset">>,<<"utf-8">>}],
           %case V of
           %     "DKIM_SIGNED" -> process_results(_Head,_RKey,T, [list_to_binary(V++"<br>"++[A || {<<"dkim-signature", _/binary>>,A} <- _Head]++"<br>")|Results]),
           %      rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results])
           %end;

           %process_results(T, [list_to_binary(V++"<br>")|Results]),
           %process_results(T, [list_to_binary(V++"<br>")|Results]),

           %process_results(_RKey,[V="T_DKIM_INVALID"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           %process_results(_RKey,[V="DKIM_INVALID"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           
           %process_results(_RKey,[V="NO_RELAYS"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           
           %process_results(_RKey,[V="RDNS_NONE"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           %process_results(_RKey,[V="URIBL_BLOCKED"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           %process_results(_RKey,[V="HELO_MISC_IP"|T], Results) ->
           %process_results(_RKey,T, [list_to_binary(V++"<br>")|Results]),
           %rabbit_log:info("CHOPPE LE RESULTS ~p" , [Results]);

           process_results(Id,State,_RKey,[_|T],Draft_Score, Results) ->
           process_results(Id,State,_RKey,T,Draft_Score,Results).

tothefront2(State,Tab,Id,RoutingKey) ->

		{ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
    		{ok, Connection} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = <<"/">>, host = Host, port = Port}),
    		{ok, Channel} = amqp_connection:open_channel(Connection),
    		amqp_channel:call(Channel, #'exchange.declare'{exchange = <<"pipe_results">>,type = <<"fanout">>, durable = true}),
                %Props = #'P_basic'{delivery_mode = 2, headers = [{<<"To">>, longstr, RoutingKey},{<<"Toooo">>, longstr, RoutingKey}]},
	        L = ets:lookup(Tab, Id),
	        Smart = func(L),
    	        rabbit_log:info("Lookup from table ~p~n", [L]),
		rabbit_log:info("Headers ready ~p ~n",[Smart]),
                %Props = #'P_basic'{delivery_mode = 2, headers = func(L)},
                %Props = #'P_basic'{delivery_mode = 2, headers = [{<<"De">>,longstr,<<"sebastien BRICE <sebastien.brice@opentelecom.fr>">>},{<<"Routing_key">>,longstr,<<"seb@mail-testing.com">>},{<<"Date">>,longstr,<<"Tue, 25 May 2021 21:30:54 +0200">>},{<<"Dkim_valid">>,longstr,1},{<<"Spf_pass">>,longstr,1},{<<"Ipv6">>,longstr,1}]},
                Props = #'P_basic'{delivery_mode = 2, headers = [{<<"to">>, longstr, RoutingKey},{<<"dkim_valid">>, signedint, 1}]},
    		amqp_channel:cast(Channel,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = <<"{\"name\":\"Tom\",\"age\":10}">>}),
    		ok = amqp_channel:close(Channel),
    		ok = amqp_connection:close(Connection),
    		ok.

func([T]) ->
        V = tuple_to_list(T),
%       io:format("V func1 ~p ~n",[V]),
        func2(V).

func2([H|U]) ->
        %io:format("func 2 ~p ~n",[U]),
        U.

tothefront(Id,RoutingKey,Argv) ->

    %% SNIPPET IMPORTANT
    %%log en base couchdb
    %{ok, Server} = couchdb:server_record(<<"http://localhost:5984">>),
    %       rabbit_log:info("COUCHDB Server ~p" , [Server]),
    %{ok, Db} = couchdb:database_record(Server, <<"mail-testing">>, []),
    %       rabbit_log:info("COUCHCDB Db ~p" , [Db]),
    %Doc = #{<<"_id">> => RoutingKey,<<"name">> => Argv,<<"Date">>  => Date},
    %couchdb_documents:save(Db,Doc,[]),
    %       rabbit_log:info("COUCHDB Doc ~p" , [Doc]),
	
    %SEB
	   %%{_,U} = ets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]),
           % PW = ets:match(U,{Id,'$1','$2','$3','$4','$5','$6','$7','$8','$9','$10','$11','$12'}), %$1-2 de $3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
	   %rabbit_log:info("PATTERN ds la BASE ~p ~n",[PW]),
	%SEB

%case dets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
%   	{ok, Ref} -> dets:update_counter(?MODULE,Id,{9,1});
%   	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
    

%       <<X:64/big-unsigned-integer>> = crypto:strong_rand_bytes(8),
       Random = crypto:bytes_to_integer(crypto:strong_rand_bytes(3)),
       io:format("le Random qui sert de ref ~p ~n",[Random]),
	
    %AMQP
    {ok,Cred = [Username,Password,Host,Port]} = application:get_env(broker_email, credentials),
    {ok, Connection2} = amqp_connection:start(#amqp_params_network{username = Username, password = Password,virtual_host = <<"/">>, host = Host, port = Port}),
    %{ok, Connection2} = amqp_connection:start(#amqp_params_network{virtual_host = <<"/">>}),
    {ok, Channel2} = amqp_connection:open_channel(Connection2),
    amqp_channel:call(Channel2, #'exchange.declare'{exchange = <<"pipe_results">>,type = <<"fanout">>, durable = true}),
            Props = #'P_basic'{delivery_mode = 2, headers = [{<<"To">>, longstr, RoutingKey},{<<"Ref">>, signedint , Random} ]},
    %amqp_channel:cast(Channel2,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = <<"SALUT\nMONGARS\nTUPUS\nAHOUI\n\n">>}),
   amqp_channel:cast(Channel2,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = Argv}),


    ok = amqp_channel:close(Channel2),
    ok = amqp_connection:close(Connection2),
    ok.

terminate(_Reason, #state{connection=Connection, channel=Channel}) ->
	amqp_channel:close(Channel),
	amqp_connection:close(Connection),
        %ets:close(?MODULE),
	ok.

code_change(_OldVsn, State, _Extra) ->
{ok, State}.
