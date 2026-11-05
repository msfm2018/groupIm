-module(imdemo_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% 必须先启动 pg，否则 chat_registry 的 join/leave 会报 noproc
    case whereis(pg) of
        undefined ->
            {ok, _} = pg:start_link();
        _ ->
            ok
    end,
    %% 在线用户 ETS 表
    chat_registry:ensure_started(),

    case chat_db:start() of
        ok ->
            Dispatch = cowboy_router:compile([
                {'_', [
                    {"/register", register_handler, []},
                    {"/login", login_handler, []},
                    {"/upload", upload_handler, []},
                    {"/files/:name", file_handler, []},
                    {"/ws", ws_handler, []}
                ]}
            ]),

            %% 启动 HTTP + WebSocket
            {ok, _} = cowboy:start_clear(
                http_listener,
                [{port, 8080}],
                #{
                    env => #{dispatch => Dispatch},
                    max_connections => infinity
                }
            ),

            io:format("========================================~n"),
            io:format("Cowboy 已启动，监听端口 8080~n"),
            io:format("HTTP 登录:  POST http://localhost:8080/login~n"),
            io:format("WebSocket:  ws://localhost:8080/ws?token=xxx~n"),
            io:format("========================================~n"),

            imdemo_sup:start_link();
        {error, Reason} ->
            {error, {chat_db_start_failed, Reason}}
    end.

stop(_State) ->
    ok.