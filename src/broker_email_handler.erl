%
% This Source Code Form is subject to the terms of the Mozilla Public
% License, v. 2.0. If a copy of the MPL was not distributed with this
% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%
% Copyright (C) 2014 Petr Gotthard <petr.gotthard@centrum.cz>
%
% Based on smtp_server_example
% Copyright 2009-2011 Andrew Thompson <andrew@hijacked.us>
%

-module(broker_email_handler).
-behaviour(gen_smtp_server_session).

-export([init/4, handle_HELO/2, handle_EHLO/3, handle_MAIL/2, handle_MAIL_extension/2,
    handle_RCPT/3, handle_RCPT_extension/2, handle_DATA/4, handle_RSET/1, handle_VRFY/2,
    handle_other/3, handle_AUTH/4, handle_STARTTLS/1, handle_info/2,
    code_change/3, terminate/2]).

-record(state, {
    hostname,
    hostname_client,
    auth_user,
    sender_pid,
    %du state pour prendre en compte le champs (enveloppe-from) dans Received
    addr = <<>> :: binary(),
    options = [] :: list() }).

-define(AUTH_REQUIRED, "530 SMTP authentication is required").
-include_lib("kernel/include/logger.hrl").

init(Hostname, SessionCount, Address, Options) when SessionCount < 20 ->
    io:format("~s EMAIL_HANDLER SMTP connection from Domain et Address ~p~n", [Hostname, Address]),
    rabbit_log:info("~s EMAIL_HANDLER SMTP connection from Domain et Address ~p~n", [Hostname, Address]),
    process_flag(trap_exit, true),
    {ok, SenderPid} = broker_message_sender:start_link(Hostname),

    Banner = [Hostname, " ESMTP broker_email_handler"],
    Hostname_client = [],
    State = #state{hostname=Hostname, hostname_client = Hostname_client,sender_pid=SenderPid, addr=Address, options=Options},
    {ok, Banner, State};

init(Hostname, _SessionCount, _Address, _Options) ->
    %rabbit_log:warning("EMAIL_HANDLER Connection limit exceeded~n"),
    {stop, normal, ["421 ", Hostname, " is too busy to accept mail right now"]}.

handle_HELO(Hostname, State) ->
    rabbit_log:info("EMAIL_HANDLER HELO from ~s~n", [Hostname]),
    case application:get_env(broker_email, server_auth) of
        {ok, false} ->
            {ok, 655360, set_user_as_anonymous(State,Hostname)}; % 640kb should be enough for anyone
        _Else ->
            % we expect EHLO will come
            {ok, State} % use the default 10mb limit
    end.

handle_EHLO(Hostname, Extensions, State) ->
    Ip = State#state.addr,
    SenderPid = State#state.sender_pid,
    rabbit_log:info("EMAIL_HANDLER EHLO addr ~s~n", [Ip]),
    rabbit_log:info("EMAIL_HANDLER EHLO from ~s~n", [Hostname]),
    rabbit_log:info("EMAIL_HANDLER EHLO State ~p~n", [State]),
	    WithTlsExts = Extensions ++ [{"STARTTLS", true}],
            NewState = #state{hostname_client=Hostname,sender_pid=SenderPid,addr=Ip},
	        {ok, WithTlsExts, NewState}.
%handle_EHLO(Hostname, Extensions, State) ->
%    rabbit_log:info("EMAIL_HANDLER EHLO from ~s~n", [Hostname]),
%    ExtensionsTLS = starttls_extension(Extensions),
%    case application:get_env(broker_email, server_auth) of
%        {ok, false} ->
%            {ok, ExtensionsTLS, set_user_as_anonymous(State,Hostname)};
%        {ok, rabbitmq} ->
%            {ok, [{"AUTH", "PLAIN LOGIN"} | ExtensionsTLS], State}
%    end.

set_user_as_anonymous(State,Hostname) ->
    State#state{auth_user=anonymous,hostname=Hostname}.

starttls_extension(Extensions) ->
    case application:get_env(broker_email, server_starttls) of
        {ok, false} -> Extensions;
        {ok, true} -> [{"STARTTLS", true} | Extensions]
    end.

handle_MAIL(_From, State=#state{auth_user=undefined}) ->
    %rabbit_log:error("EMAIL_HANDLER SMTP authentication is required~n"),
    %{error, ?AUTH_REQUIRED, State};
    {ok, State};
handle_MAIL(_From, State) ->
    % you can accept or reject the FROM address here
    {ok, State}.

handle_MAIL_extension(_Extension, _State) ->
    %rabbit_log:warning("EMAIL_HANDLER Unknown MAIL FROM extension ~s~n", [Extension]),
    error.

%handle_RCPT(_From, State=#state{auth_user=undefined}) ->
%    rabbit_log:error("EMAIL_HANDLER SMTP authentication is not required~n"),
%    %{error, ?AUTH_REQUIRED, State};
%    {ok, State};
handle_RCPT(To, State, []) ->
    rabbit_log:info("EMAIL_HANDLER handle_RCPT Blacklisted ~p ~n", [To]),
    % you can accept or reject RCPT TO addesses here, one per call
    {error, <<"Not permitted to enter">>, State};
handle_RCPT(To, State, _) ->
    rabbit_log:info("EMAIL_HANDLER handle_RCPT Whitelisted ~p ~n", [To]),
    % you can accept or reject RCPT TO addesses here, one per call
    {ok, State}.

handle_RCPT_extension(_Extension, _State) ->
    %rabbit_log:warning("EMAIL_HANDLER Unknown RCPT TO extension ~s~n", [Extension]),
    error.

handle_DATA(_From, _To, <<>>, State) ->
    {error, "552 Message too small", State};
handle_DATA(_From, To, Data, State=#state{hostname=Hostname,hostname_client = Hostname_client,sender_pid=SenderPid,addr=Address}) ->
    % some kind of unique id
    Reference = lists:flatten([io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(term_to_binary(os:timestamp()))]),
            rabbit_log:info("EMAIL_HANDLER FILTER Hostname ~s ~n", [Hostname]),
            rabbit_log:info("EMAIL_HANDLER FILTER Hostname_client ~s ~n", [Hostname_client]),
            rabbit_log:info("EMAIL_HANDLER FILTER Address ~s ~n", [Address]),

   case email_filter:extract_payload(Data,Hostname_client,inet:ntoa(Address)) of
        {ok, _ContentType, Headers, _Body } ->
            rabbit_log:info("EMAIL_HANDLER FILTER Headers ~s ~n", [Headers]),
            rabbit_log:info("EMAIL_HANDLER raboutage Headers avec From ~s ~n", [_From]),
	    %NewHeaders = firsts(Headers,_From),
            %rabbit_log:info("EMAIL_HANDLER raboutage FIRSTS ~s ~n", [NewHeaders]),

   	    gen_server:cast(SenderPid, {Reference, To, <<"application/mime">>, Headers, Data, _From}),
            {ok, Reference, State};
        error ->
            {error, "554 Message cannot be delivered", State}
   end.

   %gen_server:cast(SenderPid, {Reference, To, <<"application/mime">>, [], Data, _From}),

handle_RSET(State) ->
    % reset any relevant internal state
    State.

handle_VRFY(_Address, State) ->
    {error, "252 VRFY disabled by policy, just send some mail", State}.

handle_other(Verb, _Args, State) ->
    % You can implement other SMTP verbs here, if you need to
    {["500 Error: command not recognized : '", Verb, "'"], State}.

handle_AUTH(Type, Username, Password, State) when Type =:= login; Type =:= plain ->
    case application:get_env(broker_email, server_auth) of
        {ok, rabbitmq} ->
            case rabbit_access_control:check_user_pass_login(Username, Password) of
                {ok, AuthUser} ->
                    {ok, State#state{auth_user=AuthUser}};
                {refused, _U, F, A} ->
                    rabbit_log:error(F, A),
                    error
            end;
        {ok, false} ->
            % authentication is disabled; whatever you send is fine
            {ok, State#state{auth_user=anonymous}}
    end;
handle_AUTH('cram-md5', <<"username">>, {Digest, Seed}, State) ->
    case smtp_util:compute_cram_digest(<<"PaSSw0rd">>, Seed) of
        Digest -> {ok, State};
        _ -> error
    end;
handle_AUTH(_Type, _Username, _Password, _State) ->
    error.

handle_STARTTLS(State) ->
    rabbit_log:info("EMAIL_HANDLER TLS Started~n"),
    State.

handle_info({'EXIT', SenderPid, _Reason}, #state{sender_pid=SenderPid} = State) ->
    % sender failed, we terminate as well
    {stop, normal, State};

handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    rabbit_log:info("~w~n", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, #state{sender_pid=SenderPid} = State) ->
    rabbit_log:warning("BROKER_EMAIL_HANDLER terminate ~n"),
    gen_server:cast(SenderPid, stop),
    {ok, Reason, State}.

% end of file
