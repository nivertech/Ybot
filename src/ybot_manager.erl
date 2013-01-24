%%%----------------------------------------------------------------------
%%% File    : ybot_manager.erl
%%% Author  : 0xAX <anotherworldofworld@gmail.com>
%%% Purpose : Ybot main manager. Run transport, load plugins.
%%%----------------------------------------------------------------------
-module(ybot_manager).

-behaviour(gen_server).

-export([start_link/2, load_plugin/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

-record(state, {
       % ybot transports list (irc, xmpp and etc..)
       % Example : [{irc, ClientPid, HandlerPid, Nick, Channel, Host}]
       transports = [],
       % Ybot active plugins list
       plugins = [] :: [{plugin, Source :: string(), PluginName :: string(), Path :: string()}]
    }).

start_link(PluginsDirectory, Transports) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [PluginsDirectory, Transports], []).

init([PluginsDirectory, Transports]) ->
    % init plugins
    ok = gen_server:cast(?MODULE, {init_plugins, PluginsDirectory}),
    % Start transports
    ok = gen_server:cast(?MODULE, {start_transports, Transports}),
    % init
    {ok, #state{}}.

%% @doc Get plugin metadata by plugin name
handle_call({get_plugin, PluginName}, _From, State) ->
    case lists:keyfind(PluginName, 3, State#state.plugins) of
        false ->
            % there is no plugin with `PluginName`
            {reply, wrong_plugin, State};
        Plugin ->
            % return plugin with metadata
            {reply, Plugin, State}
    end;

%% @doc Return all plugins
handle_call(get_plugins, _From, State) ->
    {reply, State#state.plugins, State};

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @doc Init active plugins
handle_cast({init_plugins, PluginsDirectory}, State) ->
    case filelib:is_dir(PluginsDirectory) of
        true ->
            % Get all plugins
            PluginsPaths = ybot_utils:get_all_files(PluginsDirectory),
            % Parse plugins and load to state
            Plugins = lists:flatten(lists:map(fun load_plugin/1, PluginsPaths)),
            % Get checking_new_plugins parameter from config
            {ok, UseNewPlugins} = application:get_env(ybot, checking_new_plugins),
            % Check checking_new_plugins
            case UseNewPlugins of
                true ->
                    % Get new plugins checking timeout
                    {ok, NewPluginsCheckingTimeout} = application:get_env(ybot, checking_new_plugins_timeout),
                    % Start new plugins observer
                    ybot_plugins_observer:start_link(PluginsDirectory, Plugins, NewPluginsCheckingTimeout);
                _ ->
                    % don't use new plugins
                    pass
            end,
            % return plugins
            {noreply, State#state{plugins = Plugins}};
        false ->
            % some log
            lager:error("Unable to load plugins. Invalid directory ~s", [PluginsDirectory]),
            % return empty plugins list
            {noreply, State#state{plugins = []}}
    end;

%% @doc Run transports from `Transports` list
handle_cast({start_transports, Transports}, State) ->
    % Review supported mode of transportation
    TransportList = lists:flatten(lists:map(fun load_transport/1, Transports)),
    {noreply, State#state{transports = TransportList}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions

%% @doc Start irc clients
load_transport({irc, Nick, Channel, Host, Options}) ->
    % Get irc server port
    {port, Port} = lists:keyfind(port, 1, Options),
    % Start irc handler
    {ok, HandlerPid} = irc_handler:start_link(),
    % Check use irc with ssl or not
    case lists:keyfind(use_ssl, 1, Options) of
        % Start without ssl
        {use_ssl, false} ->
            % Run new irc client
            {ok, ClientPid} = irc_lib_sup:start_irc_client(HandlerPid, Host, Port, Channel, Nick, false),
            % Log
            lager:info("Starting IRC transport: ~s, ~p, ~s", [Host, Channel, Nick]),
            % send client pid to handler
            ok = gen_server:cast(HandlerPid, {irc_client, ClientPid, Nick}),
            % return correct transport
            {irc, ClientPid, HandlerPid, Nick, Channel, Host, Port};
        % Start ssl
        {use_ssl, true} ->
            io:format("Start with SSL ~n"),
            % Start irc client with ssl
            {ok, ClientPid} = irc_lib_sup:start_irc_client(HandlerPid, Host, Port, Channel, Nick, true),
            % Log
            lager:info("Starting IRC transport: ~s, ~p, ~s", [Host, Channel, Nick]),
            % send client pid to handler
            ok = gen_server:cast(HandlerPid, {irc_client, ClientPid, Nick}),
            % return correct transport
            {irc, ClientPid, HandlerPid, Nick, Channel, Host, Port};
        % Wrong options
        _ ->
            % Stop handler
            gen_server:cast(HandlerPid, stop),
            % Log error
            lager:error("Wrong irc options ~p~n", [Options])
    end;

%% @doc start xmpp clients
load_transport({xmpp, Login, Password, Room, Host, Resource}) ->
    % Start xmpp handler
    {ok, HandlerPid} = xmpp_handler:start_link(),
    % Run new xmpp client
    {ok, ClientPid} = xmpp_sup:start_xmpp_client(HandlerPid, Login, Password, Host, Room, Resource),
    % Log
    lager:info("Starting XMPP transport: ~s, ~s, ~s", [Host, Room, Resource]),
    % Send client pid to handler
    ok = gen_server:cast(HandlerPid, {xmpp_client, ClientPid, Login}),
    % return correct transport
    {xmpp, ClientPid, HandlerPid, Login, Password, Host, Room, Resource};

%% @doc start campfire clients
load_transport({campfire, Login, Token, RoomId, CampfireSubDomain}) ->
    % Start campfire handler
    {ok, HandlerPid} = campfire_handler:start_link(),
    % Run new campfire client
    {ok, ClientPid} = campfire_sup:start_campfire_client(HandlerPid, RoomId, Token, CampfireSubDomain),
    % Log
    lager:info("Starting Campfire transport: ~p, ~s", [RoomId, CampfireSubDomain]),
    % Send client pid to handler
    ok = gen_server:cast(HandlerPid, {campfire_client, ClientPid, Login}),
    % return correct transport
    {campfire, ClientPid, HandlerPid}.

load_plugin(Plugin) ->
    % Get plugin extension
    Ext = filename:extension(Plugin),
    Name = filename:basename(Plugin, Ext),
    % Match extension
    case Ext of
        ".py" ->
            % python plugin
            lager:info("Loading plugin(Python): ~s", [Name]),
            {plugin, "python", Name, Plugin};
        ".rb" ->
            % ruby plugin
            lager:info("Loading plugin(Ruby): ~s", [Name]),
            {plugin, "ruby", Name, Plugin};
        ".sh" ->
            % shell plugin
            lager:info("Loading plugin(Shell): ~s", [Name]),
            {plugin, "sh", Name, Plugin};
        ".pl" ->
            % perl plugin
            lager:info("Loading plugin(Perl) ~s", [Name]),
            {plugins, "perl", Name, Plugin};
        ".ex" ->
            % elixir plugin
            lager:info("Loading plugin(Elixir) ~s", [Name]),
            {plugins, "elixir", Name, Plugin};
        _ ->
            % this is wrong plugin
            lager:info("Unsupported plugin type: ~s", [Ext]),
            []
    end.
