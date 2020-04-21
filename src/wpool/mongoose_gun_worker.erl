-module(mongoose_gun_worker).

-behaviour(gen_server).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2]).

-record(state, {host :: inet:hostname() | inet:ip_address(),
                port :: inet:port_number(),
                opts :: gun:opts(),
                pid :: pid() | undefined,
                monitor :: reference() | undefined}).

-type request() :: {request,
                    Path::iodata(),
                    Method::iodata(),
                    Headers::gun:headers(),
                    Query::iodata(),
                    Retries::pos_integer(),
                    Timeout::non_neg_integer()}.

-include("mongoose_logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link(Destination, Options) ->
    gen_server:start_link(?MODULE, {Destination, Options}, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init({{inet:hostname() | inet:ip_address(), inet:port_number()}, gun:opts()}) ->
    {ok, State :: #state{}}.
init({{Host, Port}, Opts}) ->
    {ok, #state{host = Host, port = Port, opts = maps:merge(default_opts(), Opts)}}.

-spec handle_call(Request :: request(), From :: {pid(), Tag :: term()}, State :: #state{}) ->
                     {reply, Reply :: term(), NewState :: #state{}}.
handle_call({request, FullPath, Method, Headers, Query, Retries, Timeout}, _From, State) ->
    LHeaders = lowercase_headers(Headers),
    NewState = create_or_get_connection(State),
    Res = send_request(FullPath, Method, LHeaders, Query, Retries + 1, Timeout, NewState#state.pid),
    {reply, Res, NewState}.

-spec handle_cast(any(), State :: #state{}) -> {noreply, State :: #state{}}.
handle_cast(_R, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, _PID, _Reason}, #state{monitor = MRef} = State) ->
    {noreply, State#state{pid = undefined, monitor = undefined}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

create_or_get_connection(#state{pid = undefined} = State) ->
    {ok, PID} = gun:open(State#state.host, State#state.port, State#state.opts),
    {ok, _Protocol} = gun:await_up(PID),
    State#state{pid = PID, monitor = monitor(process, PID)};
create_or_get_connection(#state{pid = PID, monitor = MRef} = State) ->
    receive
        {'DOWN', MRef, process, PID, _Reason} ->
            {ok, NewPID} = gun:open(State#state.host, State#state.port, State#state.opts),
            {ok, _Protocol} = gun:await_up(NewPID),
            State#state{pid = NewPID, monitor = monitor(process, NewPID)}
    after 0 ->
        State
    end.

send_request(_FullPath, _Method, _LHeaders, _Query, 0, _Timeout, _PID) ->
    {error, request_timeout};
send_request(FullPath, Method, LHeaders, Query, Retries, Timeout, PID) ->
    StreamRef = gun:request(PID, Method, FullPath, LHeaders, Query),
    case timer:tc(fun() -> gun:await(PID, StreamRef, Timeout) end) of
        {Time, {response, fin, Status, _H}} ->
            {ok, {{integer_to_binary(Status), reason}, resp_headers, no_data, 0, Time}};
        {Time, {response, nofin, Status, _H}} ->
            {ok, B} = gun:await_body(PID, StreamRef),
            {ok, {{integer_to_binary(Status), reason}, resp_headers, B, byte_size(B), Time}};
        {_Time, {error, timeout}} ->
            send_request(FullPath, Method, LHeaders, Query, Retries - 1, Timeout, PID);
        {_Time, {E, R}} ->
            ?WARNING_MSG("Error in gun_server: ~p, Reason: ~p", [E, R]),
            {E, R}
    end.

default_opts() ->
    #{protocols => [http2]}.

lowercase_headers(Headers) ->
    [{string:lowercase(K), V} || {K, V} <- Headers].
