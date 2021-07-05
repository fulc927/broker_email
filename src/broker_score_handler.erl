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
-export([laliste_increment/1,laliste/2,process_results/6, tothefront/5, tothefront2/5]).
-record(state, {connection, channel,routing_key,id,dkim,received,table,date}).
-define(FILENAME,"SEBFILE").
-define(FILENAME2,"SEBFILE2").
-define(BUILTIN_EXTENSIONS, [{"DKIM_VALID", true}]).
-include_lib("amqp_client/include/amqp_client.hrl").

start_link({VHost, Queue}, Domain, Rkey) ->
    gen_server:start_link(?MODULE, [{VHost, Queue}, Domain, Rkey], []).

init([{VHost, Queue}, _Domain, Rkey]) ->
    process_flag(trap_exit, true),
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
                            routing_key = H},
                #'queue.bind_ok'{} = amqp_channel:call(Channel, Binding),
    pick_the_rk(Connection, Queue, T);
    pick_the_rk(Connection, Queue,[]) -> {ok, Channel} = amqp_connection:open_channel(Connection),
                                     Subscribe = #'basic.consume'{queue=Queue, consumer_tag= <<"otp.fr.eu.org">>, no_ack=true},
                                     #'basic.consume_ok'{} = amqp_channel:call(Channel, Subscribe),
				     Routing_key="",
				     Id="",
				     Date="",
				     Dkim="",
                                     State = #state{connection=Connection, channel=Channel,routing_key=Routing_key, id=Id, dkim=Dkim, date=Date},
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
	{ok, Dir} -> file:write_file(Dir++"email/new/mail-"++Reference2++".txt", Payload)
    	end,
	
    #'P_basic'{message_id = _MessageId, headers = Headers } = Properties,
    rabbit_log:info("RABBIT_SCORE_PERSO to SPAMASSASSIN ~p" , [Payload]),
    rabbit_log:info("RABBIT_SCORE_PERSO messageid ~p" , [_MessageId]),
    Headers2 = transform_headers(Headers),
    rabbit_log:info("RABBIT_SCORE_PERSO Headers ~s ~n ", [Headers]),
    rabbit_log:info("RABBIT_SCORE_PERSO Headers2 ~s ~n ", [Headers2]),

    Date = proplists:get_value(<<"Date">>,Headers2),
    rabbit_log:info("RABBIT_SCORE_PERSO Date ~s ~n ", [Date]),
    De = proplists:get_value(<<"From">>,Headers2),
    rabbit_log:info("RABBIT_SCORE_PERSO De ~s ~n ", [De]),
    Dkim = proplists:get_value(<<"DKIM-Signature">>,Headers2,"Pas de signature DKIM détectée"),
    rabbit_log:info("RABBIT_SCORE_PERSO Headers2 ~s ~n ", [Dkim]),
    calcule_score(RKey, Payload),

    Table = ets:new(?MODULE, [set, public]),
		%ets:insert(Table,{Reference2,{<<"de">>,longstr,De},{<<"routing_key">>,longstr,RKey},{<<"date">>,longstr,Date},{<<"dkim_valid">>,longstr,0},{<<"spf_pass">>,longstr,0},{<<"ipv6">>,longstr,0}}), %$3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
		ets:insert(Table,{Reference2,<<"de">>,longstr,De,<<"routing_key">>,longstr,RKey,<<"date">>,longstr,Date,<<"dkim_valid">>,signedint,0,<<"spf_pass">>,signedint,0,<<"ipv6">>,signedint,0}), %$3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
              %PW = ets:match(Table,{Reference2,'$1','$2','$3','$4','$5','$6','$7','$8','$9','$10','$11','$12'}), %$1-2 de $3-4 routing_key, $5-6 date, $7-8 dkim_valid $9-10 spf_pass $11-12 ipv6
	   %rabbit_log:info("PATTERN ds la BASE ~p ~n",[PW]),
    
    NewState = State#state{routing_key= RKey, id= Reference2,dkim=Dkim,date=Date,table=Table},
    {noreply,  NewState };

%%On choppe la réponse de SA
handle_info(Msg, State) ->
    case Msg of
        {_,_,Data} ->
	   rabbit_log:info("XXX RABBIT_SCORE_PERSO retour de SPAMASSASSIN (c'est un binary string) ~p" , [Data]),
	   RKey = State#state.routing_key,
	   rabbit_log:info("XXX RABBIT_SCORE_PERSO retour le routing key ~p" , [RKey]),
	   Id = State#state.id,
	   rabbit_log:info("rabbit_broker_score WEB field Id ~p ~n",[Id]),
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

has_extension(Exts, Ext) ->
	Extension = string:to_upper(Ext),
	%_Extensions = [{string:to_upper(X), Y} || {X, Y} <- Exts],
	%io:format("extensions ~p~n", [Extensions]),
	_Exteeensions = [{"EMPTY_MESSAGE",true},{"DKIM_VALID",signedint,true}],
	%case proplists:get_value(Extension, [{"SIZE", "10485670"}, {"DKIM_VALID", true}, {"PIPELINING", true}]) of
	case proplists:get_value(Extension, Exts) of
		undefined ->
			false;
		Value ->
                	rabbit_log:info("HAS_EXT a la base VALUE ~p ~n" , [Value]),
			{true, Value}
	end.

%SUPER RESULT [{"SPF_PASS",0},{"EMPTY_MESSAGE",1},{"DKIM_VALID",1}]
laliste([],T) -> T;
laliste([A|As],T) ->
	laliste(As,[laliste_increment(tuple_to_list(A))|T]).

%SUPER RESULTS 2  [{"EMPTY_MESSAGE",signedint,[1]},{"SPF_PASS",signedint,[1]},{"DKIM_VALID",signedint,[0]}]
laliste_increment([B|Bs]) ->
%	%{list_to_binary(B),signedint,list_to_binary(Bs)}.
	{list_to_binary(B),signedint,lists:last(Bs)}.

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
                rabbit_log:info("IDRISS Score2 ~p ~n" , [Score2]),
                rabbit_log:info("XSpamStatus ~p ~n" , [XSpamStatus]),

		%retour Score ==  2021-04-17 23:11:38.291 [info] <0.917.0> PARSE SCORE_HANDLER every tests SA ["Yes","score","5.4","required","-5.0","tests","DATE_IN_FUTURE_96_Q","\r\n","EMPTY_MESSAGE","HTML_MESSAGE","MISSING_SUBJECT","RDNS_NONE\r\n","autolearn","disabled","version","3.4.2"]
  		%case dets:open_file(spamassassin_table, [{file, ?FILENAME2},{type,set}]) of
   		%	{ok, Ref} -> dets:insert(spamassassin_table,{Id,Score}),
            	%	io:format("display le Score ~p ~p" , [Id,Score]);
   		%	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E])end,
		
                Sa = list_to_binary(sascore2(2,Score)),
                rabbit_log:info("PARSE SCORE_HANDLER every tests SA ~p" , [Sa]),
                %process_results(Id,State,_RKey,string:lexemes(XSpamStatus, " ,\r\n\t="),Score2,[]);
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
           rabbit_log:info("PARSE SCORE_HANDLER process_results RESULTS ~p ~n" , [Results]),
	   %proplists:get_value("DKIM_VALID",[{"DKIM_VALID",1},{"EMPTY_MESSAGE",1}])
	   %[<<"SPF_PASS">>,{"EMPTY_MESSAGE",1}]
	   Empty_message = case has_extension(Results, "EMPTY_MESSAGE") of  
		{true, Value} ->
				   rabbit_log:info("HAS_EXTENSION PAS LA ~p ~n",[Value]),
				   Results;
				   %true;
		false ->
				   rabbit_log:info("HAS_EXTENSION LA que je rajoute DKIM_VALID a zero car le message contient des data"),
				   Empty = [{"EMPTY_MESSAGE",0} | Results],
				   %true
				  Empty 
		end,
	   rabbit_log:info("PARSE SCORE_HANDLER process_results Empty_message ~p ~n" , [Empty_message]),
	   Dkim_message = case has_extension(Empty_message, "DKIM_VALID") of  
		{true, Value2} ->
				   rabbit_log:info("HAS_EXTENSION PAS LA ~p ~n",[Value2]),
				   Empty_message;
				   %true;
		false ->
				   rabbit_log:info("HAS_EXTENSION LA que je rajoute EMPTY_MESSAGE a zero car le message contient des data"),
				   Dkim = [{"DKIM_VALID",0} | Empty_message],
				   %true
				  Dkim 
		end,
	   Spf_message = case has_extension(Dkim_message, "SPF_PASS") of  
		{true, Value3} ->
				   rabbit_log:info("HAS_EXTENSION PAS LA ~p ~n",[Value3]),
				   Dkim_message;
				   %true;
		false ->
				   rabbit_log:info("HAS_EXTENSION LA que je rajoute EMPTY_MESSAGE a zero car le message contient des data"),
				   Spf = [{"SPF_PASS",0} | Dkim_message],
				   %true
				   Spf
		end,


	   rabbit_log:info("PARSE SCORE_HANDLER process_results RESULTS empty_message ~p ~n" , [Empty_message]),
	   rabbit_log:info("PARSE SCORE_HANDLER process_results SUPER RESULTS  ~p ~n" , [Spf_message]),
	   Spf_message_sort = lists:sort(Spf_message),
	   rabbit_log:info("PARSE SCORE_HANDLER process_results SUPER RESULTS sorted !  ~p ~n" , [Spf_message_sort]),
	   %SUPER RESULT [{"SPF_PASS",0},{"EMPTY_MESSAGE",1},{"DKIM_VALID",1}]

	   %O = laliste(Spf_message,[]),
	   O = laliste(Spf_message_sort,[]),
	   rabbit_log:info("PARSE SCORE_HANDLER process_results SUPER RESULTS 2  ~p ~n" , [O]),
	   

	   %A = has_extension(Results, ["DKIM_VALID",signedint]),  
           %rabbit_log:info("PARSE SCORE_HANDLER HAS_EXTENSION ~p ~n" , [A]),
	   %tothefront(State,Id,_RKey,[list_to_binary(Draft_Score)|Results],list_to_tuple(Results)),
	   tothefront(State,Id,_RKey,[list_to_binary(Draft_Score)|Results],O),
	   Tab = State#state.table,
	   %tothefront2(State,Tab,Id,_RKey,[list_to_binary(Draft_Score)|Results]),
               {ok, lists:reverse(Results)};

	   process_results(Id,State,_RKey,[V="EMPTY_MESSAGE"|T],Draft_Score, Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [{V,1}|Results]),
	   rabbit_log:info("CHOPPE LE EMPTY_MESSAGE ~p" , [Results]);

	   process_results(Id,State,_RKey,[V="DKIM_VALID"|T],Draft_Score, Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [{V,1}|Results]),
           %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
	   Tab = State#state.table,
   	   ets:update_counter(Tab,Id,{13,1}),
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
	   rabbit_log:info("LE Table ~p" , [Tab]),
	   rabbit_log:info("LE Table lookup ~p" , [ets:lookup(Tab, Id)]),
	   rabbit_log:info("CHOPPE LE DKIM_VALID ~p" , [Results]);
	  
%	   process_results(Id,State,_RKey,[V="SPF_PASS"|T],Draft_Score,Results) ->
%           %process_results(Id,State,_RKey,T,Draft_Score, [V|Results]),
%           process_results(Id,State,_RKey,T,Draft_Score, [{V,"true"}|Results]),
%	   %case ets:open_file(?MODULE, [{file, ?FILENAME},{type,set}]) of
%	   %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
%  	   Tab = State#state.table,
%   	   ets:update_counter(Tab,Id,{16,1}),
%	   %	{ok, Ref} -> ets:update_counter(?MODULE,Id,{11,1});
%   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
%           rabbit_log:info("CHOPPE LE SPF_PASS VALID ~p" , [Results]);

	   process_results(Id,State,_RKey,[V="SPF_PASS"|T],Draft_Score,Results) ->
           process_results(Id,State,_RKey,T,Draft_Score, [{V,1}|Results]),
	   %case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
   	   Tab = State#state.table,
   	   ets:update_counter(Tab,Id,{16,1}),
	   %	{ok, Ref} -> ets:update_counter(?MODULE,Id,{11,1});
   	   %	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
           rabbit_log:info("CHOPPE LE SPF_PASS\\r\\n VALID ~p" , [Results]);

	   %process_results(Id,State,_RKey,[V="MISSING_SUBJECT"|T],Draft_Score, Results) ->
           %process_results(Id,State,_RKey,T,Draft_Score, [list_to_binary(V)|Results]),
           %%case ets:new(?MODULE, [{file, ?FILENAME},{type,set}]) of
	   %%Tab = State#state.table,
   	   %%ets:update_counter(Tab,Id,{13,1}),
   	   %%	{error, Reason}=E -> rabbit_log:info("Unable to open database file: ~p~n", [E]) end,
	   %rabbit_log:info("CHOPPE LE MISSING_SUBJECT ~p" , [Results]);
	   
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

tothefront2(State,Tab,Id,RoutingKey,Argv) ->

       Random = crypto:bytes_to_integer(crypto:strong_rand_bytes(3)),
       io:format("le Random qui sert de ref ~p ~n",[Random]),

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
                %Props = #'P_basic'{delivery_mode = 2, headers = [{<<"to">>, longstr, RoutingKey},{<<"dkim_valid">>, signedint, 1}]},
                Props = #'P_basic'{delivery_mode = 2, headers = [{<<"To">>, longstr, RoutingKey},{<<"Ref">>, signedint , Random} ]},
    		%amqp_channel:cast(Channel,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = <<"{\"name\":\"Tom\",\"age\":10}">>}),
    		amqp_channel:cast(Channel,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = Argv}),
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

tothefront(State,Id,RoutingKey,Argv,Results) ->

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
    {ok, Channel2} = amqp_connection:open_channel(Connection2),
    amqp_channel:call(Channel2, #'exchange.declare'{exchange = <<"pipe_results">>,type = <<"fanout">>, durable = true}),
	   Dkim = State#state.dkim,
	   Date = State#state.date,
	   %Inedine = [{<<"To">>,longstr,RoutingKey},{<<"Ref">>,signedint,Random},{<<"Dkim">>,longstr,Dkim},{<<"Date">>,longstr,Date},{<<"SPF_PASS">>,signedint,0},{<<"EMPTY_MESSAGE">>,signedint,1},{<<"DKIM_VALID">>,signedint,0}], 
    	   Results3 = lists:append([[{<<"To">>, longstr, RoutingKey},{<<"Ref">>, signedint , Random},{<<"Dkim">>, longstr , Dkim},{<<"Date">>, longstr , Date}],Results]),
    rabbit_log:info("tothefront Results3 en test ~p ~n",[Results3]),

    Props = #'P_basic'{delivery_mode = 2, headers = Results3},
    amqp_channel:cast(Channel2,#'basic.publish'{exchange = <<"pipe_results">>},#amqp_msg{props = Props,payload = <<"uasrniteaunrtaunur">>}),
%COMMENT  [{<<"To">>,longstr,<<"c4e4dba4804b6ac3@mail-testing.com">>},{<<"Ref">>,signedint,11375183},{<<"Dkim">>,longstr,"Pas de signature DKIM détectée"},{<<"Date">>,longstr,<<"Thu, 1 Jul 2021 18:40:07 +0200">>},{<<"EMPTY_MESSAGE">>,signedint,1},{<<"DKIM_VALID">>,signedint,1}]
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
