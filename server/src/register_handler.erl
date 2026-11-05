-module(register_handler).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> -> handle_register(Req0, State);
        _ -> reply(Req0, 405, #{
            <<"code">> => 1,
            <<"msg">> => <<"Method Not Allowed">>
        }, State)
    end.

handle_register(Req0, State) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} ->
            try
                Data = jsx:decode(Body, [return_maps]),
                Username = maps:get(<<"username">>, Data, undefined),
                Password = maps:get(<<"password">>, Data, undefined),
                Nickname = maps:get(<<"nickname">>, Data, Username),
                case chat_db:register(Username, Password, Nickname) of
                    {ok, UserId, SavedNickname} ->
                        reply(Req1, 201, #{
                            <<"code">> => 0,
                            <<"msg">> => <<"注册成功，请登录 succ"/utf8>>,
                            <<"user_id">> => UserId,
                            <<"nickname">> => SavedNickname
                        }, State);
                    {error, Reason} ->
                        reply(Req1, 400, #{
                            <<"code">> => 10,
                            <<"msg">> => Reason
                        }, State)
                end
            catch
                _->
            
                    reply(Req1, 400, #{
                        <<"code">> => 1,
                        <<"msg">> => <<"注册参数错误 wrong"/utf8>>
                    }, State)
            end;
        {more, _PartialBody, Req1} ->
            reply(Req1, 413, #{
                <<"code">> => 11,
                <<"msg">> => <<"请求内容过大 big"/utf8>>
            }, State)
    end.

reply(Req, Status, Map, State) ->
    Body = jsx:encode(Map),
    Req2 = cowboy_req:reply(Status, #{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"access-control-allow-origin">> => <<"*">>
    }, Body, Req),
    {ok, Req2, State}.
