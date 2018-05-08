%% Copyright (c) 2009-2012
%% Bill Warnecke <bill@rupture.com>
%% Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% Henning Diedrich <hd2010@eonblast.com>
%% Eonblast Corporation <http://www.eonblast.com>
%%
%% Permission is  hereby  granted,  free of charge,  to any person
%% obtaining  a copy of this software and associated documentation
%% files (the "Software"),to deal in the Software without restric-
%% tion,  including  without  limitation the rights to use,  copy,
%% modify, merge,  publish,  distribute,  sublicense,  and/or sell
%% copies  of the  Software,  and to  permit  persons to  whom the
%% Software  is  furnished  to do  so,  subject  to the  following
%% conditions:
%%
%% The above  copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF  MERCHANTABILITY,  FITNESS  FOR  A  PARTICULAR  PURPOSE  AND
%% NONINFRINGEMENT. IN  NO  EVENT  SHALL  THE AUTHORS OR COPYRIGHT
%% HOLDERS  BE  LIABLE FOR  ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT,  TORT  OR OTHERWISE,  ARISING
%% FROM,  OUT OF OR IN CONNECTION WITH THE SOFTWARE  OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.


%% @doc The main Emysql module.
%%
%% Emysql is implemented as an Erlang
%% <b>application</b>. The term has a special meaning in Erlang, see
%% [http://www.erlang.org/doc/design_principles/applications.html]
%%
%% This module exports functions to:
%% <li><b>start</b> and <b>stop</b> the driver (the 'application'),</li>
%% <li><b>execute</b> queries or prepared statements,</li>
%% <li><b>prepare</b> such statements,</li>
%% <li>change the <b>connection pool</b> size.</li>
%%
%% === Sample ===
%% ```
%%  -module(sample).
%%  -export([run/0]).
%%
%%  run() ->
%%
%%      crypto:start(),
%%      emysql:start(),
%%
%%      emysql:add_pool(hello_pool, [{size,1},
%%                   {user,"hello_username"},
%%                   {password,"hello_password"},
%%                   {database,"hello_database"},
%%                   {encoding,utf8}]),
%%
%%      emysql:execute(hello_pool,
%%          <<"INSERT INTO hello_table SET hello_text = 'Hello World!'">>),
%%
%%      emysql:prepare(my_stmt, <<"SELECT * from mytable WHERE id = ?">>),
%%
%%      Result = emysql:execute(mypoolname, my_stmt, [1]).
%%
%% '''
%%
%% === Implementation ===
%%
%% Under <b>Implementation</b>, you can find details about the
%% inner workings of Emysql. If you are new to Emysql, you may safely ignore
%% them.
%%
%% start(), stop(), modules() and default_timeout() are one-line 'fascades':
%% ```
%%  start() -> application:start(emysql).
%%  stop() -> application:stop(emysql).
%%  modules() -> emysql_app:modules().
%%  default_timeout() -> emysql_app:default_timeout().
%% '''
%%
%% execute() and prepare() are the bulk of the source
%% of this module. A lot gets repeated for default values in lesser arities.
%% The quintessential execute however is this, in execute/2:
%% ```
%%  execute(PoolId, Query, Args, Timeout)
%%      when (is_list(Query) orelse is_binary(Query)) andalso is_list(Args) andalso is_integer(Timeout) ->
%%
%%          Connection =
%%              emysql_conn_mgr:wait_for_connection(PoolId),
%%              monitor_work(Connection, Timeout, {emysql_conn, execute, [Connection, Query, Args]});
%% '''
%% As all executions, it uses the monitor_work/3 function to create a process to
%% asynchronously handle the execution.
%%
%% The pool-related functions execute brief operations using the primitive
%% functions exported by `emysql_conn_mgr' and `emysql_conn_mgr'.
%% @end doc: hd feb 11

-module(emysql).


%% Life cycle API
%% These are used to handle the life-cycle of the code base
-export([   start/0, stop/0,
            add_pool/2,
            add_pool/9, add_pool/10,
            add_pool/8, remove_pool/1, increment_pool_size/2, decrement_pool_size/2
]).
        
%% Interaction API
%% Used to interact with the database.    
-export([
            prepare/2, prepare_async/2,
            execute/2, execute/3, execute/4,
            execute/5,
            transaction/3, is_commit_before_close/1,
            deallocate_prepared_stmt/1, get_all_prepared_stmts/0,
            default_timeout/0
]).

%% Result Conversion API
-export([
         as_dict/1,
         as_json/1,
         as_proplist/1,
         as_record/3,
         as_record/4
]).

%% Result Data API - Handle results from Mysql
-export([
	affected_rows/1,
	result_type/1,
        field_names/1,
         insert_id/1
]).

-type state() :: any().

% for record and constant defines
-include("emysql.hrl").

%% @spec start() -> ok
%% @doc Start the Emysql application.
%%
%% Simply calls `application:start(emysql).'
%%
%% === From the Erlang Manual ===
%% If the application is not already loaded, the application controller will
%% first load it using application:load/1. It will check the value of the
%% applications key, to ensure that all applications that should be started
%% before this application are running. The application controller then
%% creates an application master for the application. The application master
%% is the group leader of all the processes in the application. The
%% application master starts the application by calling the application
%% callback function start/2 in the module, and with the start argument,
%% defined by the mod key in the .app file.
%%
%% application:start(Application) is the same as calling
%% application:start(Application, temporary). If a temporary application
%% terminates, this is reported but no other applications are terminated.
%%
%% See [http://www.erlang.org/doc/design_principles/applications.html]
%% @end doc: hd feb 11
%%
start() ->
    application:start(emysql).

%% @spec stop() -> ok
%% @doc Stop the Emysql application.
%%
%% Simply calls `application:stop(emysql).'
%%
%% === From the Erlang Manual ===
%% It is always possible to stop an application explicitly by calling
%% application:stop/1. Regardless of the mode, no other applications will be
%% affected.
%%
%% See [http://www.erlang.org/doc/design_principles/applications.html]
%% @end doc: hd feb 11
%%
stop() ->
    application:stop(emysql).

%% @spec default_timeout() -> Timeout
%%      Timeout = integer()
%%
%% @doc Returns the default timeout in milliseconds. As set in emysql.app.src,
%% or if not set, the value ?TIMEOUT as defined in include/emysql.hrl (8000ms).
%%
%% === Implementation ===
%%
%% src/emysql.app.src is a template for the emysql app file from which
%% ebin/emysql.app is created during building, by a sed command in 'Makefile'.
%% @end doc: hd feb 11
%%
default_timeout() ->
    emysql_app:default_timeout().

%% @spec add_pool(PoolId, Options) -> Result
%%		PoolId = atom()
%%		Options = [option()]
%%		option() = {size, integer()}
%%		         | {user, string()}
%%		         | {password, string()}
%%		         | {host, string()}
%%		         | {port, integer()}
%%		         | {database, string() | undefined}
%%		         | {encoding, atom() | {atom(), atom()}}
%%		         | {start_cmds, [binary()]}
%%		         | {connect_timeout, integer()}
%%		         | {warnings, boolean()}
%%		Result = {reply, {error, pool_already_exists}, state()} | {reply, ok, state() }
%%
%% @doc Synchronous call to the connection manager to add a pool.
%%
%% Options:
%%
%% size - pool size (defaults to 1)
%% user - user to connect with (defaults to "")
%% password - user password (defaults to "")
%% host - host to connect to (defaults to "127.0.0.1")
%% port - the port to connect to (defaults to 3306)
%% database - the database to connect to (defaults to undefined)
%% encoding - the connection encoding or {encoding, collation} (defaults to utf8)
%% start_cmds - a list of commands to execute on connect
%% connect_timeout - millisecond timeout for connect or infinity (default)
%% warnings - whether to fetch and log MySQL warnings automatically (defaults to false)
%%
%% === Implementation ===
%%

% Checks whether a configuration is superficially valid. It checks types and such,
% it does not check existance of the database or correctness of passwords (that
% happens when we try to connect to the database.
config_ok(#pool{pool_id=PoolId,size=Size,user=User,password=Password,host=Host,port=Port,
		       database=Database,encoding=Encoding,start_cmds=StartCmds,
		       connect_timeout=ConnectTimeout,warnings=Warnings})
  when is_atom(PoolId),
       is_integer(Size),
       is_list(User),
       is_list(Password),
       is_list(Host),
       is_integer(Port),
       is_list(Database) orelse Database == undefined,
       is_list(StartCmds),
       is_integer(ConnectTimeout) orelse ConnectTimeout == infinity,
       is_boolean(Warnings) ->
    encoding_ok(Encoding);
config_ok(_BadOptions) ->
    erlang:error(badarg).

encoding_ok(Enc) when is_atom(Enc) ->  ok; 
encoding_ok({Enc, Coll}) when is_atom(Enc), is_atom(Coll) -> ok; 
encoding_ok(_)  ->  erlang:error(badarg).

%% Creates a pool record, opens n=Size connections and calls
%% emysql_conn_mgr:add_pool() to make the pool known to the pool management.
%% emysql_conn_mgr:add_pool() is translated into a blocking gen-server call.

add_pool(PoolId, Options) when is_list(Options) ->
    Size = proplists:get_value(size, Options, 5),
    User = proplists:get_value(user, Options, ""),
    Password = proplists:get_value(password, Options, ""),
    Host = proplists:get_value(host, Options, "127.0.0.1"),
    Port = proplists:get_value(port, Options, 3306),
    Database = proplists:get_value(database, Options, undefined),
    Encoding = proplists:get_value(encoding, Options, utf8),
    StartCmds = proplists:get_value(start_cmds, Options, []),
    ConnectTimeout = proplists:get_value(connect_timeout, Options, infinity),
    Warnings = proplists:get_value(warnings, Options, false),
    add_pool(#pool{pool_id=PoolId,size=Size, user=User, password=Password,
			  host=Host, port=Port, database=Database,
			  encoding=Encoding, start_cmds=StartCmds, 
			  connect_timeout=ConnectTimeout, warnings=Warnings}).

add_pool(#pool{pool_id=PoolId,size=Size,user=User,password=Password,host=Host,port=Port,
		       database=Database,encoding=Encoding,start_cmds=StartCmds,
		       connect_timeout=ConnectTimeout,warnings=Warnings}=PoolSettings)->
    config_ok(PoolSettings),
    case emysql_conn_mgr:has_pool(PoolId) of
        true -> 
            {error,pool_already_exists};
        false ->
            Pool = #pool{
                    pool_id = PoolId,
                    size = Size,
                    user = User,
                    password = Password,
                    host = Host,
                    port = Port,
                    database = Database,
                    encoding = Encoding,
                    start_cmds = StartCmds,
                    connect_timeout = ConnectTimeout,
                    warnings = Warnings
                    },
            Pool2 = case emysql_conn:open_connections(Pool) of
                {ok, Pool1} -> Pool1;
                {error, Reason} -> throw(Reason)
            end,
            emysql_conn_mgr:add_pool(Pool2)
    end.

%% @spec add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding) -> Result
%%
%% @doc Adds a pool using the default start commands (empty list).
%%
%% @equiv add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding, [])
%% @end

add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding) ->
    add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding, []).

%% @doc Synchronous call to the connection manager to add a pool.
%%
%% === Implementation ===
%%
%% @end doc: hd feb 11
-spec add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding, StartCmds) -> Result
    when
      PoolId :: atom(),
      Size :: integer(),
      User :: string(),
      Password :: string(),
      Host :: string(),
      Port :: integer(),
      Database :: string(),
      Encoding :: utf8 | latin1 | {utf8, utf8_unicode_ci} | {utf8, utf8_general_ci},
      StartCmds :: list(binary()),
      Result :: {reply, {error, pool_already_exists}, state()} | {reply, ok, state() }.
add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding, StartCmds) ->
    add_pool(PoolId, Size, User, Password, Host, Port, Database, Encoding, StartCmds, infinity).

add_pool(PoolId, Size, User, Password, Host, Port, Database, 
	 Encoding, StartCmds, ConnectTimeout)->    
    add_pool(PoolId,[{size,Size},{user,User},{password,Password},
		     {host,Host},{port,Port},{database,Database},
		     {encoding,Encoding},{start_cmds,StartCmds},
		     {connect_timeout,ConnectTimeout}]).

%% @spec remove_pool(PoolId) -> ok
%%      PoolId = atom()
%%
%% @doc Synchronous call to the connection manager to remove a pool.
%%
%% === Implementation ===
%%
%% Relies on emysql_conn:close_connection(Conn) for the proper closing of connections. Feeds
%% any connection in the pool to it, also the locked ones.
%% @end doc: hd feb 11

remove_pool(PoolId) ->
    Pool = emysql_conn_mgr:remove_pool(PoolId),
    [emysql_conn:close_connection(Conn) || Conn <- lists:append(queue:to_list(Pool#pool.available), gb_trees:values(Pool#pool.locked))],
    ok.

-spec increment_pool_size(atom(), non_neg_integer()) -> ok | {error, list()}.
increment_pool_size(PoolId, Num) when is_integer(Num) ->
    {Conns, Reasons} = emysql_conn:open_n_connections(PoolId, Num),
    emysql_conn_mgr:add_connections(PoolId, Conns),
    case Reasons of
        [] -> ok;
        _ -> {error, Reasons}
    end.


%% @spec decrement_pool_size(PoolId, By) -> ok
%%      PoolId = atom()
%%      By = integer()
%%
%% @doc Synchronous call to the connection manager to shrink a pool.
%%
%% This reduces the connections by up to n=By, but it only drops and closes available
%% connections that are not in use at the moment that this function is called. Connections
%% that are waiting for a server response are never dropped. In heavy duty, this function
%% may thus do nothing.
%%
%% If 'By' is higher than the amount of connections or the amount of available connections,
%% exactly all available connections are dropped and closed.
%%
%%
%% === Implementation ===
%%
%% First gets a list of target connections from emysql_conn_mgr:remove_connections(), then
%% relies on emysql_conn:close_connection(Conn) for the proper closing of connections.
%% @end doc: hd feb 11
%%

decrement_pool_size(PoolId, Num) when is_integer(Num) ->
    Conns = emysql_conn_mgr:remove_connections(PoolId, Num),
    [emysql_conn:close_connection(Conn) || Conn <- Conns],
    ok.

%% @spec prepare(StmtName, Statement) -> ok
%%      StmtName = atom()
%%      Statement = binary() | string()
%%
%% @doc Prepare a statement.
%%
%% The atom given by parameter 'StmtName' is bound to the SQL string
%% 'Statement'. Calling ``execute(<Pool>, StmtName, <ParamList>)'' executes the
%% statement with parameters from ``<ParamList>''.
%%
%% This is not a mySQL prepared statement, but an implementation on the side of
%% Emysql.
%%
%% === Sample ===
%% ```
%% -module(sample).
%% -export([run/0]).
%%
%% run() ->
%%
%%  application:start(sasl),
%%  crypto:start(),
%%  application:start(emysql),
%%
%%  emysql:add_pool(hello_pool, [{size,1},
%%      {user,"hello_username"},
%%      {password,"hello_password"},
%%      {database,"hello_database"},
%%      {encoding,utf8}]),
%%
%%  emysql:execute(hello_pool,
%%      <<"INSERT INTO hello_table SET hello_text = 'Hello World!'">>),
%%
%%  emysql:prepare(hello_stmt,
%%      <<"SELECT * from hello_table WHERE hello_text like ?">>),
%%
%%  Result = emysql:execute(hello_pool, hello_stmt, ["Hello%"]),
%%
%%   io:format("~n~s~n", [string:chars($-,72)]),
%%   io:format("~p~n", [Result]),
%%
%%     ok.
%% '''
%% Output:
%% ```
%% {result_packet,32,
%%               [{field,2,<<"def">>,<<"hello_database">>,
%%                        <<"hello_table">>,<<"hello_table">>,
%%                        <<"hello_text">>,<<"hello_text">>,254,<<>>,33,
%%                        60,0,0}],
%%                [[<<"Hello World!">>]],
%%                <<>>}
%% '''
%% === Implementation ===
%%
%% Hands parameters over to emysql_statements:add/2:
%% ``emysql_statements:add(StmtName, Statement).'', which calls
%% ``handle_call({add, StmtName, Statement}, _From, State)''.
%%
%% The statement is there added to the Emysql statement GB tree:
%% ... ```
%%              State#state{
%%                  statements = gb_trees:enter(StmtName, {1, Statement},
%%                      State#state.statements)
%% '''
%% Execution is called like this:
%% ```
%% execute(Connection, StmtName, Args) when is_atom(StmtName), is_list(Args) ->
%%  prepare_statement(Connection, StmtName),
%%  case set_params(Connection, 1, Args, undefined) of
%%      OK when is_record(OK, ok_packet) ->
%%          ParamNamesBin = list_to_binary(string:join([[$@ | integer_to_list(I)] || I <- lists:seq(1, length(Args))], ", ")),
%%          StmtNameBin = atom_to_binary(StmtName, utf8),
%%          Packet = <<?COM_QUERY, "EXECUTE ", StmtNameBin/binary, " USING ", ParamNamesBin/binary>>,
%%          emysql_tcp:send_and_recv_packet(Connection#emysql_connection.socket, Packet, 0);
%%      Error ->
%%          Error
%%  end.
%% '''
%%
%% @see emysql_statements:add/2
%% @see emysql_statements:handle/3
%% @see emysql_conn:execute/3
%% @end doc: hd feb 11

prepare(StmtName, Statement) when is_atom(StmtName) andalso (is_list(Statement) orelse is_binary(Statement)) ->
    emysql_statements:add(StmtName, Statement).

prepare_async(StmtName, Statement) when is_atom(StmtName) andalso (is_list(Statement) orelse is_binary(Statement)) ->
    emysql_statements:add_async(StmtName, Statement).

%% @spec execute(PoolId, Query|StmtName) -> Result | [Result]
%%      PoolId = atom()
%%      Query = binary() | string()
%%      StmtName = atom()
%%      Result = ok_packet() | result_packet() | error_packet()
%%
%% @doc Execute a query, prepared statement or a stored procedure.
%%
%% Same as `execute(PoolId, Query, [], default_timeout())'.
%%
%% The result is a list for stored procedure execution >= MySQL 4.1
%%
%% @see execute/3.
%% @see execute/4.
%% @see execute/5.
%% @see prepare/2.
%% @end doc: hd feb 11
%%
execute(PoolId, Query) when (is_list(Query) orelse is_binary(Query)) ->
    execute(PoolId, Query, []);

execute(PoolId, StmtName) when is_atom(StmtName) ->
    execute(PoolId, StmtName, []).

%% @spec execute(PoolId, Query|StmtName, Args|Timeout) -> Result | [Result]
%%      PoolId = atom()
%%      Query = binary() | string()
%%      StmtName = atom()
%%      Args = [any()]
%%      Timeout = integer() | infinity
%%      Result = ok_packet() | result_packet() | error_packet()
%%
%% @doc Execute a query, prepared statement or a stored procedure.
%%
%% Same as `execute(PoolId, Query, Args, default_timeout())'
%% or `execute(PoolId, Query, [], Timeout)'.
%%
%% Timeout is the query timeout in milliseconds or the atom infinity.
%%
%% The result is a list for stored procedure execution >= MySQL 4.1
%%
%% @see execute/2.
%% @see execute/4.
%% @see execute/5.
%% @see prepare/2.
%% @end doc: hd feb 11
%%

execute(PoolId, Query, Args) when (is_list(Query) orelse is_binary(Query)) andalso is_list(Args) ->
    execute(PoolId, Query, Args, default_timeout());
execute(PoolId, StmtName, Args) when is_atom(StmtName), is_list(Args) ->
    execute(PoolId, StmtName, Args, default_timeout());
execute(PoolId, Query, Timeout) when (is_list(Query) orelse is_binary(Query)) andalso (is_integer(Timeout) orelse Timeout == infinity) ->
    execute(PoolId, Query, [], Timeout);
execute(PoolId, StmtName, Timeout) when is_atom(StmtName), (is_integer(Timeout) orelse Timeout == infinity) ->
    execute(PoolId, StmtName, [], Timeout).

%% @spec execute(PoolId, Query|StmtName, Args, Timeout) -> Result | [Result]
%%      PoolId = atom()
%%      Query = binary() | string()
%%      StmtName = atom()
%%      Args = [any()]
%%      Timeout = integer() | infinity
%%      Result = ok_packet() | result_packet() | error_packet()
%%
%% @doc Execute a query, prepared statement or a stored procedure.
%%
%% <ll>
%% <li>Opens a connection,</li>
%% <li>sends the query string, or statement atom, and</li>
%% <li>returns the result packet.</li>
%% </ll>
%%
%% Basically:
%% ```
%% Connection = emysql_conn_mgr:wait_for_connection(PoolId),
%% monitor_work(Connection, Timeout, {emysql_conn, execute, [Connection, Query_or_StmtName, Args]}).
%% '''
%% Timeout is the query timeout in milliseconds or the atom infinity.
%%
%% All other execute function eventually call this function.
%%
%% @see execute/2.
%% @see execute/3.
%% @see execute/5.
%% @see prepare/2.
%% @end doc: hd feb 11
%%

execute(PoolId, Query, Args, Timeout) when (is_list(Query) orelse is_binary(Query)) andalso is_list(Args) andalso (is_integer(Timeout) orelse Timeout == infinity) ->
    %-% io:format("~p execute getting connection for pool id ~p~n",[self(), PoolId]),
    Connection = emysql_conn_mgr:wait_for_connection(PoolId),
    %-% io:format("~p execute got connection for pool id ~p: ~p~n",[self(), PoolId, Connection#emysql_connection.id]),
    monitor_work(Connection, Timeout, [Connection, Query, Args]);
execute(PoolId, StmtName, Args, Timeout)
  when
    is_atom(StmtName),
    is_list(Args),
    is_integer(Timeout) orelse Timeout == infinity ->
    Connection = emysql_conn_mgr:wait_for_connection(PoolId),
    monitor_work(Connection, Timeout, [Connection, StmtName, Args]).

%% @spec execute(PoolId, Query|StmtName, Args, Timeout, nonblocking) -> Result | [Result]
%%      PoolId = atom()
%%      Query = binary() | string()
%%      StmtName = atom()
%%      Args = [any()]
%%      Timeout = integer() | infinity
%%      Result = ok_packet() | result_packet() | error_packet()
%%
%% @doc Execute a query, prepared statement or a stored procedure - but return immediately, returning the atom 'unavailable', when no connection in the pool is readily available without wait.
%%
%% <ll>
%% <li>Checks if a connection is available,</li>
%% <li>returns 'unavailable' if not,</li>
%% <li>else as the other exception functions(): sends the query string, or statement atom, and</li>
%% <li>returns the result packet.</li>
%% </ll>
%%
%% Timeout is the query timeout in milliseconds or the atom infinity.
%%
%% ==== Implementation ====
%%
%% Basically:
%% ```
%% {Connection, connection} = case emysql_conn_mgr:lock_connection(PoolId),
%%      monitor_work(Connection, Timeout, {emysql_conn, execute, [Connection, Query_or_StmtName, Args]}).
%% '''
%%
%% The result is a list for stored procedure execution >= MySQL 4.1
%%
%% All other execute function eventually call this function.
%%
%% @see execute/2.
%% @see execute/3.
%% @see execute/4.
%% @see prepare/2.
%% @end doc: hd feb 11
%%
execute(PoolId, Query, Args, Timeout, nonblocking) when (is_list(Query) orelse is_binary(Query)) andalso is_list(Args) andalso (is_integer(Timeout) orelse Timeout == infinity) ->
    case queue_or_stay_conn(PoolId) of
        Connection when is_record(Connection, emysql_connection) ->
            monitor_work(Connection, Timeout, [Connection, Query, Args], nonblocking);
        unavailable ->
            unavailable
    end;

execute(PoolId, StmtName, Args, Timeout, nonblocking) when is_atom(StmtName), is_list(Args) andalso is_integer(Timeout) ->
    case queue_or_stay_conn(PoolId) of
        Connection when is_record(Connection, emysql_connection) ->
            monitor_work(Connection, Timeout, [Connection, StmtName, Args], nonblocking);
        unavailable ->
            unavailable
    end.

queue_or_stay_conn(PoolId) ->
    case dict_conn_get(PoolId) of
    Connection = #emysql_connection{} -> 
        Connection;
    undefined -> 
        emysql_conn_mgr:lock_connection(PoolId) 
    end.

%%deallocate_prepared_stmt_test(PoolId) ->
%%    case queue_or_stay_conn(PoolId) of
%%    Connection = #emysql_connection{id = ConnId} ->
%%        StmtsL = emysql_statements:remove(ConnId),   
%%        io:format(" deallocate_prepared_stmt_test/1  ConnId:~ts, [~w] ~n", [ConnId, StmtsL]),
%%        [emysql_conn:unprepare(Connection, StmtName) || StmtName <- StmtsL];
%%    unavailable ->
%%        unavailable
%%    end.

%% @spec deallocate_prepared_stmt(PoolId) -> empty | DoneUnPreparedNum 
%%
%% @doc
deallocate_prepared_stmt(PoolId) ->
    case emysql_conn_mgr:get_all_conns(PoolId) of
    [] -> empty;
    Connections ->
        do_unprepare_all_conns_stmts(Connections, 0)
    end.

do_unprepare_all_conns_stmts([], DoneUnPreparedNum) -> 
    DoneUnPreparedNum;
do_unprepare_all_conns_stmts([Connection = #emysql_connection{id = ConnId} | T], DoneUnPreparedNum) -> 
    StmtsL = emysql_statements:remove(ConnId),   
   
    [emysql_conn:unprepare(Connection, StmtName) || StmtName <- StmtsL],
    %%io:format("~p, ~n",[UnpResult]),
    do_unprepare_all_conns_stmts(T, DoneUnPreparedNum + erlang:length(StmtsL)).

get_all_prepared_stmts() ->
    Stmts = emysql_statements:all_prepared_stmts(),
    flatten_statments(Stmts, []).

flatten_statments([], DoneL) -> 
    DoneL;
flatten_statments([{_ConnId, Stmts} | T], DoneL) -> 
    flatten_statments(T, [StmtName || {StmtName, _Version}<- Stmts] ++ DoneL).

%% @spec transaction(PoolId, Fun, Timeout) -> Result
%%      PoolId = atom()
%%      Fun = funtion() a closeure function with execute/5 , support INSERT INTO | UPDATE | DELETE | SELECT , 
%%      Do not using DDL in this function 
%%      return {error, Reason = term()} do rollback , any other Return = term() do commit
%%
%%      Timeout = integer() 
%%      
%%      Result  = {atomic, FunEvalResult} | {rollback, RollbackRet, Err}
%%      FunEvalResult = term() Fun evaluate return Rest
%%
%%      RollbackRet   = {ok, AffRow} | {error, {SqlErrNo, SqlErrMsgStr}}    
%%      Err     = {error, Resaon}
%% @doc do transaction with closure Fun,  support no nesting
transaction(PoolId, Fun, TimeOut) -> 
    case begin_start(TimeOut, PoolId) of
    {error, Reason} -> 
        RollbackRet = rollback(TimeOut, PoolId),
        {rollback, RollbackRet, Reason};
    _BeginOk -> 
        case catch Fun() of
        {error, _Reason} = Err -> 
            RollbackRet = rollback(TimeOut, PoolId),
            {rollback, RollbackRet, Err};
        {'EXIT', _} = Err -> 
            RollbackRet = rollback(TimeOut, PoolId),
            {rollback, RollbackRet, Err};
        Res -> 
            case commit(TimeOut, PoolId) of
            {error, _Reason} = Err-> 
                RollbackRet = rollback(TimeOut, PoolId),
                {rollback, RollbackRet, Err};
            {ok, _AffRow} -> 
                {atomic, Res} 
            end
        end
    end.

%% keep different transaction of sessions(connections) in same isolation level 
begin_start(TimeOut, PoolId) ->
    declaration(<<"START TRANSACTION WITH CONSISTENT SNAPSHOT;">>, PoolId, TimeOut, start_transaction).

commit(TimeOut, PoolId) ->
    declaration(<<"COMMIT;">>, PoolId, TimeOut, commit).

rollback(TimeOut, PoolId) -> 
    declaration(<<"ROLLBACK;">>, PoolId, TimeOut, rollback).

declaration(SqlStatement, PoolId, TimeOut, Declar) ->
    %%io:format(" tsql: ~ts ~n", [SqlStatement]),
    case execute_transaction(PoolId, SqlStatement, [], TimeOut, Declar) of
    [#ok_packet{
        affected_rows = AffectedRows,
        %%warning_count = _WarningCount,
        msg           = _MsgString
    }|_] -> 
        {ok, AffectedRows};
    #ok_packet{
        affected_rows = AffectedRows,
        %%warning_count = _WarningCount,
        msg           = _MsgString
    } ->  
        {ok, AffectedRows};
    #error_packet{
        code = ErrNo,
        msg  = ErrMsgStr
    } ->
        {error, {ErrNo, ErrMsgStr}}
    end.

%% @doc use the same Connection execute transaction process, when after commit / rollback pass this Connection 
execute_transaction(
    PoolId, StmtNameOrQuery, Args, Timeout, Declaration
) when ((is_list(StmtNameOrQuery) orelse is_binary(StmtNameOrQuery)) andalso is_list(Args) andalso (is_integer(Timeout) orelse Timeout == infinity))
        orelse
       (is_atom(StmtNameOrQuery) andalso is_list(Args) andalso is_integer(Timeout))
->
    case load_stay_conn(Declaration, PoolId) of
        Connection when is_record(Connection, emysql_connection) ->
            monitor_work(Connection, Timeout, [Connection, StmtNameOrQuery, Args], Declaration);
        unavailable ->
            unavailable
    end.

load_stay_conn(start_transaction, PoolId) -> 
    case dict_conn_get(PoolId) of
    undefined ->
        case emysql_conn_mgr:lock_connection_hold(PoolId) of
            Connection = #emysql_connection{} -> 
                Connection;
            unavailable ->
                unavailable     
        end;
    _Conn -> 
        exit({re_transaction_start, PoolId})
    end;
load_stay_conn(_OtherDeclaration, PoolId) ->
    case dict_conn_get(PoolId) of
    Connection = #emysql_connection{} -> 
        Connection;
    undefined -> 
        exit({no_transaction_start, _OtherDeclaration})
    end.

set_stay_conn(start_transaction, PoolId, Connection) -> 
    dict_conn_set(PoolId, Connection);
set_stay_conn(_OtherDeclaration, _PoolId, _Connoection) ->
    pass.

%% during transaction don't test connection
is_no_transaction(PoolId) -> 
    dict_conn_get(PoolId) =:= undefined.

dict_conn_get(PoolId) -> 
    erlang:get({'@transaction_conn', PoolId}).

dict_conn_set(PoolId, Connection) -> 
    erlang:put({'@transaction_conn',PoolId}, Connection).

dict_conn_erase(PoolId) -> 
    erlang:erase({'@transaction_conn',PoolId}).

is_pass_conn(DeclarationAtom, PoolId, Connection) when DeclarationAtom =:= rollback; DeclarationAtom =:= commit -> 
    dict_conn_erase(PoolId),   
    emysql_conn_mgr:pass_connection_hold(Connection),
    pass_conn_ok;
is_pass_conn(_DeclarationAtom, PoolId, Connection) ->
    case dict_conn_get(PoolId) of
    Connection ->     
        hold;
    undefined -> 
        emysql_conn_mgr:pass_connection(Connection),
        pass_conn_ok
    end.
    
%% decrement_pool_size/2 only clear available connection 
is_commit_before_close(Connection = #emysql_connection{pool_id = PoolId, id = PortUnqId}) -> 
    case dict_conn_get(PoolId) of
    Connection ->
        dict_conn_erase(PoolId),
        emysql_conn:execute(Connection, <<"COMMIT;">>, []),
        ok; 
    _Other -> 
        case emysql_conn_mgr:get_connection_hold_status(PortUnqId) of
        true  -> emysql_conn:execute(Connection, <<"COMMIT;">>, []); %% when close connect from other process, check this connecion's hold status(is in trancactioning)
        false -> ignore
        end,
        %%io:format("is_commit_before_close/2 ~w", [_Other]),
        ok
    end.

%% @doc Return the field names of a result packet
%% @end
-spec field_names(Result) -> [Name]
  when
    Result :: #result_packet{},
    Name :: binary().
field_names(#result_packet{field_list=FieldList}) ->
    [Field#field.name || Field <- FieldList].

%% @doc insert_id/1 extracts the Insert ID from an OK Packet
%% @end
-spec insert_id(#ok_packet{}) -> integer() | binary().
insert_id(#ok_packet{insert_id=ID}) ->
    ID.

%% @doc affected_rows/1 extracts the number of affected rows from an OK Packet
%% @end
-spec affected_rows(#ok_packet{}) -> integer().
affected_rows(#ok_packet{affected_rows=Rows}) ->
    Rows.

%% @doc result_type/1 decodes a packet into its type
%% @end
result_type(#ok_packet{})     -> ok;
result_type(#result_packet{}) -> result;
result_type(#error_packet{})  -> error;
result_type(#eof_packet{})    -> eof.

%% @doc package row data as a dict
%%
%% -module(fetch_example).
%%
%% fetch_foo() ->
%%  Res = emysql:execute(pool1, "select * from foo"),
%%  Res:as_dict(Res).
-spec as_dict(Result) -> Dict
  when
    Result :: #result_packet{},
    Dict :: dict:dict().
as_dict(Res) -> emysql_conv:as_dict(Res).


%% @doc package row data as erlang json (jsx/jiffy compatible)
as_json(Res) -> emysql_conv:as_json(Res).

%% @spec as_proplist(Result) -> proplist
%%      Result = #result_packet{}
%%
%% @doc package row data as a proplist
%%
%% -module(fetch_example).
%%
%% fetch_foo() ->
%%  Res = emysql:execute(pool1, "select * from foo"),
%%  Res:as_proplist(Res).
-spec as_proplist(Result) -> [PropRow]
   when
     Result :: #result_packet{},
     PropRow :: proplists:proplist().
as_proplist(Res) -> emysql_conv:as_proplist(Res).

%% @equiv as_record(Res, Recname, Fields, fun(A) -> A end)
as_record(Res, Recname, Fields) -> emysql_conv:as_record(Res, Recname, Fields).

%% @spec as_record(Result, RecordName, Fields, Fun) -> Result
%%      Result = #result_packet{}
%%      RecordName = atom()
%%      Fields = [atom()]
%%      Fun = fun()
%%      Result = [Row]
%%      Row = [record()]
%%
%% @doc package row data as records
%%
%% RecordName is the name of the record to generate.
%% Fields are the field names to generate for each record.
%%
%% -module(fetch_example).
%%
%% fetch_foo() ->
%%  Res = emysql:execute(pool1, "select * from foo"),
%%  Res:as_record(foo, record_info(fields, foo)).
as_record(Res, Recname, Fields, Fun) -> emysql_conv:as_record(Res, Recname, Fields, Fun).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%% @spec monitor_work(Connection, Timeout, {M, F, A}) -> Result | exit()
%%      PoolId = atom()
%%      Query = binary() | string()
%%      StmtName = atom()
%%      Args = [any()]

%%      Timeout = integer() | infinity
%%      Result = ok_packet() | result_packet() | error_packet()
%%
%% @doc Execute a query, prepared statement or a stored procedure.
%%
%% Same as `execute(PoolId, Query, Args, default_timeout())'
%% or `execute(PoolId, Query, [], Timeout)'.
%%
%% Timeout is the query timeout in milliseconds or the atom infinity.
%%
%% The result is a list for stored procedure execution >= MySQL 4.1
%%
%% @see execute/2.
%% @see execute/3.
%% @see execute/4.
%% @see execute/5.
%% @see prepare/2.
%%
%% @private
%% @end doc: hd feb 11
%%
monitor_work(Connection = #emysql_connection{}, Timeout, Args) ->
    monitor_work(Connection, Timeout, Args, blocking).

monitor_work(Connection0 = #emysql_connection{pool_id = PoolId}, Timeout, Args, Declaration) when is_record(Connection0, emysql_connection) ->
    Connection = case emysql_conn:need_test_connection(Connection0) andalso is_no_transaction(PoolId) of
       true ->
          emysql_conn:test_connection(Connection0, keep);
       false ->
          Connection0
    end,

    %% may be after tcp_connection_closed set new Connection from Declaration
    set_stay_conn(Declaration, PoolId, Connection),

    %% spawn a new process to do work, then monitor that process until
    %% it either dies, returns data or times out.
    Parent = self(),
    {Pid, Mref} = spawn_monitor(
                    fun() ->
                            put(query_arguments, Args),
                            Parent ! {self(), erlang:apply(emysql_conn, execute, Args)}
                    end),
    receive
        {'DOWN', Mref, process, Pid, tcp_connection_closed} ->
            case emysql_conn:reset_connection(emysql_conn_mgr:pools(), Connection, keep) of
                NewConnection when is_record(NewConnection, emysql_connection) ->
                    %% re-loop, with new connection.
                    [_ | OtherArgs] = Args,
                    monitor_work(NewConnection, Timeout , [NewConnection | OtherArgs], Declaration);
                {error, FailedReset} ->
                    exit({connection_down, {and_conn_reset_failed, FailedReset}})
            end;
        {'DOWN', Mref, process, Pid, Reason} ->
            %% if the process dies, reset the connection
            %% and re-throw the error on the current pid.
            %% catch if re-open fails and also signal it.
            case emysql_conn:reset_connection(emysql_conn_mgr:pools(), Connection, pass) of
                {error,FailedReset} ->
                    exit({Reason, {and_conn_reset_failed, FailedReset}});
                _ -> exit({Reason, {}})
            end;
        {Pid, Result} ->
            %% if the process returns data, unlock the
            %% connection and collect the normal 'DOWN'
            %% message send from the child process
            erlang:demonitor(Mref, [flush]),
            is_pass_conn(Declaration, PoolId, Connection),
            Result
    after Timeout ->
        %% if we timeout waiting for the process to return,
        %% then reset the connection and throw a timeout error
        erlang:demonitor(Mref, [flush]),
        exit(Pid, kill),
        emysql_conn:reset_connection(emysql_conn_mgr:pools(), Connection, pass),
        exit(mysql_timeout)
    end.
