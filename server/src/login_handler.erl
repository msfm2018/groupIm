-module(login_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            handle_login(Req0, State);
        _ ->
            reply(Req0, 405, #{
                <<"code">> => 1,
                <<"msg">> => <<"Method Not Allowed">>
            }, State)
    end.

handle_login(Req0, State) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} ->
            try
                Data = jsx:decode(Body, [return_maps]),
                Username = maps:get(<<"username">>, Data, undefined),
                Password = maps:get(<<"password">>, Data, undefined),
                case chat_db:login(Username, Password) of
                    {ok, UserId, Nickname, Token} ->
                        reply(Req1, 200, #{
                            <<"code">> => 0,
                            <<"msg">> => <<"登录成功"/utf8>>,
                            <<"token">> => Token,
                            <<"user">> => Username,
                            <<"user_id">> => UserId,
                            <<"nickname">> => Nickname
                        }, State);
                    {error, Reason} ->
                        reply(Req1, 401, #{
                            <<"code">> => 1,
                            <<"msg">> => Reason
                        }, State)
                end
            catch
                _ ->
                    reply(Req1, 400, #{
                        <<"code">> => 1,
                        <<"msg">> => <<"参数错误"/utf8>>
                    }, State)
            end;
        {more, _PartialBody, Req1} ->
            reply(Req1, 413, #{
                <<"code">> => 1,
                <<"msg">> => <<"请求内容过大"/utf8>>
            }, State)
    end.

reply(Req, Status, Map, State) ->
    Body = jsx:encode(Map),
    Req2 = cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Body, Req),
    {ok, Req2, State}.
