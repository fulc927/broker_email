%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014-2015 Petr Gotthard <petr.gotthard@centrum.cz>
%

-module(email_filter).
-export([extract_payload/3]).

extract_payload(Data,Rabout1,Rabout2) ->
    case application:get_env(broker_email, email_filter) of
        % filtering is disable, just pass on the entire e-mail
        {ok, false} ->
            {ok, <<"application/mime">>, [], Data};
        % extract the useful content
        _Else ->
            case filter_body(Data) of
                %{send, {Type,Subtype,Headers,Params,Body}} when is_binary(Body) ->
                {send, {Type,Subtype,Headers,Params,Body}} ->
                    {ok, <<Type/binary, $/, Subtype/binary>>, extract_headers(Headers, Params,Rabout1,Rabout2), Body};
                {send, Multipart} ->
		    rabbit_log:info("FILTER 9999 MAUVAIS CHEMIN ! on shunte le extract_headers"),
                    {ok, <<"application/mime">>, [], mimemail:encode(Multipart)};
                {empty, {_,_,Headers,Params,_}} ->
                    {ok, <<>>, extract_headers(Headers, Params,Rabout1,Rabout2), <<>>};
                drop ->
                    error
            end
    end.

extract_headers(Headers, Params,Server,Ip) ->
        ContentTypeParams = proplists:get_value(<<"content-type-params">>, Params, []),
        AllHeaders = lists:merge(Headers, ContentTypeParams),
AllHeaders_transient = lists:merge(AllHeaders,[{<<"Serveur">>,Server}]),
AllHeaders_final = lists:merge(AllHeaders_transient,[{<<"Ip">>,list_to_binary(Ip)}]),
	rabbit_log:info("700 FILTER le AllHeaders_final qui doit contenir tous les headers du mess ~p ~n",[AllHeaders_final]),
        lists:filter(fun filter_header/1, AllHeaders_final).

filter_header({Name, _Value}) ->
    Name2 = string:to_lower(binary_to_list(Name)),
    {ok, Filter} = application:get_env(broker_email, email_headers),
    rabbit_log:info("FILTER la liste des headers imporants ~p ~n",[Filter]),
    lists:member(Name2, Filter).

filter_body(Data) when is_binary(Data) ->
    try mimemail:decode(Data) of
        {T,S,H,A,P} -> 
	rabbit_log:info("100 FILTER retour decode ~p ~p ~p ~p ~p ~n",[T,S,H,A,P]),
	rabbit_log:info("101 FILTER subtype et parts seront passes a filter_multipart ~p |||| ~p ~n",[S,P]),
	rabbit_log:info("102 FILTER faut tester si le body est binaire ~p ~n",[P]),
	filter_body({T,S,H,A,P})
    catch
    What:Why ->
        rabbit_log:error("Message decode FAILED with ~p:~p~n", [What, Why]),
        drop
    end;

filter_body({<<"multipart">>, Subtype, Header, _Params, Parts}=Parent) ->
    % pass 1: filter undersirable content
    rabbit_log:info("299 FILTER_multipart angulaire ~p ~n",filter_multipart(Subtype, Parts)),
    case filter_multipart(Subtype, Parts) of
        [] ->
            drop;
        [{Type2, Subtype2, _Header2, Params2, Parts2}] ->
            rabbit_log:info("400 FILTER Pass2 retour filter_multipart T.S.H.P.A | ~p| ~p| ~p| ~p| ~p ~n",[Type2,Subtype2,_Header2,Params2,Parts2]),
	    rabbit_log:info("400 ----------------------"),
            rabbit_log:info("400 FILTER Pass2 on preserve le Header qui vient de decode Header, Header2 ~p , ~p ~n",[Header,_Header2]),
            % keep the top-most headers
            % FIXME: some top-most should be preserved, but not Content-Type
            {send, {Type2, Subtype2, Header, Params2, Parts2}};
        Parts3 when is_list(Parts3) ->
            rabbit_log:info("450 FILTER Pass3 retour filter_multipart verifie is_list(Parts3) ~p ~n",[Parts3]),
            % pass 2: select the best part
            {ok, Filter} = application:get_env(broker_email, email_filter),
            Seb = best_multipart(Parts3, [], Parent),
	    rabbit_log:info("490 FILTER best_multipart avec filter vide [] ~p ~n",[Seb]),
            {send, Seb}
    end;

filter_body({<<"text">>, Subtype, Header, Params, Text}) ->
    % remove leading and trailing whitespace
    Text2 = re:replace(Text, "(^\\s+)|(\\s+$)", "", [global, {return, binary}]),
    % convert DOS to Unix EOL
    Text3 = binary:replace(Text2, <<16#0D, 16#0A>>, <<16#0A>>, [global]),
    % do not send empty body
    %if
        %byte_size(Text3) > 0 ->
            % rabbit_log:info("Parsing text/~p~n", [Subtype]),
            {send, {<<"text">>, Subtype, Header, Params, Text3}};
        %Subtype == <<"plain">> ->
        %    {empty, {<<"text">>, Subtype, Header, Params, <<>>}};
        %true ->
        %    drop
    %end;

% remove proprietary formats
filter_body({<<"application">>, <<"ms-tnef">>, _H, _A, _P}) -> drop;
% and accept the rest
filter_body(Body) -> {send, Body}.

% when text/plain in multipart/alternative is empty, the entire body is empty
filter_multipart(<<"alternative">>, List) ->
    case filter_bodies(List) of
        {_, true} -> [];
        {Acc, false} -> 
	rabbit_log:info("300 FILTER filter_multipart Pass3 ou 2 ~p ~n",[Acc]),		    
        Acc
    end;

filter_multipart(_, List) ->
    {Acc, _} = filter_bodies(List),
    Acc.

filter_bodies(List1) ->
    lists:foldr(
        fun (Elem, {Acc, WasEmpty}) ->
	    rabbit_log:info("200 FILTER filter_bodies les Elem ils sortent d ou? ~p ~n",[Elem]),
            case filter_body(Elem) of
                {send,Value} -> {[Value|Acc], WasEmpty};
                {empty,_} -> {Acc, true};
                drop -> {Acc, WasEmpty}
            end
        end, {[], false}, List1).

best_multipart(Parts, [{Type, SubType} | OtherPrios], BestSoFar) when is_binary(Type), is_binary(SubType) ->
    rabbit_log:info("XXX FILTER b_m1"),
    Better = lists:foldl(
        fun (Body1, undefined) -> Body1;
            (_, {T2, S2, _, _, _}=Body2) when T2==Type, S2==SubType -> Body2;
            ({T3, S3, _, _, _}=Body3, _) when T3==Type, S3==SubType -> Body3;
            (_, {T4, _, _, _, _}=Body4) when T4==Type -> Body4;
            ({T5, _, _, _, _}=Body5, _) when T5==Type -> Body5;
            (_, Else) -> Else
        end, BestSoFar, Parts),
    best_multipart(Parts, OtherPrios, Better);

best_multipart(Parts, [{Type, undefined} | OtherPrios], BestSoFar) when is_binary(Type) ->
    rabbit_log:info("XXX FILTER b_m2"),
    Better = lists:foldl(
        fun (Body1, undefined) -> Body1;
            (_, {T2, _, _, _, _}=Body2) when T2==Type -> Body2;
            ({T3, _, _, _, _}=Body3, _) when T3==Type -> Body3;
            (_, Else) -> Else
        end, BestSoFar, Parts),
    best_multipart(Parts, OtherPrios, Better);

best_multipart(Parts, [{undefined, undefined} | OtherPrios], BestSoFar) ->
    rabbit_log:info("XXX FILTER b_m3"),
    Better = lists:foldl(
        fun (Body1, undefined) -> Body1;
            (_, Else) -> Else
        end, BestSoFar, Parts),
    best_multipart(Parts, OtherPrios, Better);

best_multipart(Parts, [], BestSoFar) ->
    rabbit_log:info("451 FILTER b_m4"),
    rabbit_log:info("451 FILTER La liste qui est applique a la fonction ~p ~n",[Parts]),
    lists:foldl(
        fun (Body1, undefined) -> Body1; (_, Else) -> Else end,
       	BestSoFar,
       	Parts).
% end of file

