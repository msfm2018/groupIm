-module(ws_handler).
-behaviour(cowboy_websocket).

-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2,
    terminate/3
]).

-define(GROUP_ID, <<"__group__">>).

%% ============================================================
%% WebSocket 握手：真正验证 Token
%% ============================================================

init(Req0, _State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Token = proplists:get_value(<<"token">>, Qs, undefined),

    case chat_db:authenticate(Token) of
        {ok, UserId} ->
            case chat_db:get_user(UserId) of
                {ok, User} ->
                    Nickname = maps:get(nickname, User, UserId),

                    State = #{
                        token => Token,
                        user_id => UserId,
                        nickname => Nickname
                    },

                    {
                        cowboy_websocket,
                        Req0,
                        State,
                        #{
                            idle_timeout => 60000,
                            max_frame_size => 1024 * 1024
                        }
                    };

                _ ->
                    reject(Req0)
            end;

        _ ->
            reject(Req0)
    end.

reject(Req0) ->
    Req = cowboy_req:reply(
        401,
        #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
        <<"Token 无效，请重新登录">>,
        Req0
    ),
    {ok, Req, undefined}.

%% ============================================================
%% WebSocket 连接成功
%% ============================================================

websocket_init(State) ->
    UserId = maps:get(user_id, State),
    Nickname = maps:get(nickname, State),

    %% 注册在线用户（带昵称）
    chat_registry:register(UserId, Nickname),

    io:format(
        "[WS] 用户上线: ~s (~s)~n",
        [UserId, Nickname]
    ),

    Welcome = #{
        <<"type">> => <<"welcome">>,
        <<"msg">> => <<"连接成功"/utf8>>,
        <<"user_id">> => UserId,
        <<"nickname">> => Nickname
    },

    {reply, {text, jsx:encode(Welcome)}, State}.

%% ============================================================
%% 收到客户端文本消息
%% ============================================================

websocket_handle({text, Msg}, State) ->
    try
        Data = jsx:decode(Msg, [return_maps]),
        handle_msg(Data, State)
    catch
        Class:Reason ->
            io:format(
                "[WS] 消息处理异常: ~p:~p~n",
                [Class, Reason]
            ),

            send_error(<<"消息处理失败">>, State)
    end;

websocket_handle({binary, Bin}, State) ->
    io:format(
        "[WS] 收到二进制消息: ~p bytes~n",
        [byte_size(Bin)]
    ),
    {ok, State};

websocket_handle(_Frame, State) ->
    {ok, State}.

%% ============================================================
%% 心跳
%% ============================================================

handle_msg(
    #{<<"type">> := <<"ping">>},
    State
) ->
    send_json(#{
        <<"type">> => <<"pong">>,
        <<"ts">> => erlang:system_time(millisecond)
    }, State);

%% ============================================================
%% 公共群聊和私人单聊
%% ============================================================

handle_msg(
    #{
        <<"type">> := <<"chat">>,
        <<"message">> := Content
    } = Data,
    State
) when is_binary(Content), byte_size(Content) > 0 ->

    case maps:get(<<"to">>, Data, null) of
        null ->
            %% 没有指定接收者：公共群聊
            send_group_message(Content, State);

        ToId when is_binary(ToId), byte_size(ToId) > 0 ->
            %% 指定接收者：私人单聊
            send_direct_message(ToId, Content, State);

        _ ->
            send_error(<<"接收对象格式错误">>, State)
    end;

%% ============================================================
%% 查询聊天记录
%% ============================================================

handle_msg(
    #{<<"type">> := <<"history">>} = Data,
    State
) ->
    case maps:get(<<"room">>, Data, undefined) of
        <<"group">> ->
            send_history(?GROUP_ID, <<"group">>, State);

        _ ->
            FriendId = maps:get(<<"friend_id">>, Data, undefined),

            case FriendId of
                Friend when is_binary(Friend), byte_size(Friend) > 0 ->
                    send_history(Friend, <<"direct">>, State);

                _ ->
                    send_error(<<"聊天对象不能为空">>, State)
            end
    end;

%% ============================================================
%% 获取在线用户列表（所有已登录用户，可直接私聊）
%% ============================================================

handle_msg(
    #{<<"type">> := <<"online_list">>},
    State
) ->
    MyId = maps:get(user_id, State),

    Users = [
        #{
            <<"user_id">> => Uid,
            <<"nickname">> => Nick,
            <<"online">> => true
        }
        || {Uid, Nick} <- chat_registry:online_users(),
           Uid =/= MyId
    ],

    send_json(#{
        <<"type">> => <<"online_list">>,
        <<"users">> => Users
    }, State);

%% 兼容旧客户端仍发 friend_list
handle_msg(
    #{<<"type">> := <<"friend_list">>},
    State
) ->
    handle_msg(#{<<"type">> => <<"online_list">>}, State);

%% ============================================================
%% 未知消息
%% ============================================================

handle_msg(Other, State) ->
    io:format("[WS] 未知消息: ~p~n", [Other]),
    send_error(<<"不支持的消息类型">>, State).

%% ============================================================
%% 发送公共群聊消息
%% ============================================================

send_group_message(Content, State) ->
    UserId = maps:get(user_id, State),

    case chat_db:save_message(UserId, ?GROUP_ID, Content) of
        {ok, Timestamp} ->

            Payload = #{
                <<"type">> => <<"chat">>,
                <<"room">> => <<"group">>,
                <<"from">> => UserId,
                <<"to">> => ?GROUP_ID,
                <<"message">> => Content,
                <<"timestamp">> => Timestamp
            },

            %% 广播给所有其他在线用户
            chat_registry:broadcast(Payload),

            %% 给发送者确认
            send_json(#{
                <<"type">> => <<"chat_sent">>,
                <<"room">> => <<"group">>,
                <<"timestamp">> => Timestamp
            }, State);

        {error, Reason} ->
            io:format("[WS] 群聊保存失败: ~p~n", [Reason]),
            send_error(<<"群聊消息保存失败">>, State)
    end.

%% ============================================================
%% 发送私人单聊消息
%% ============================================================

send_direct_message(ToId, Content, State) ->
    UserId = maps:get(user_id, State),

    case ToId =:= UserId of
        true ->
            send_error(<<"不能给自己发送私人消息">>, State);

        false ->
            case chat_db:get_user(ToId) of
                {ok, _User} ->
                    save_and_send_direct(ToId, Content, State);

                _ ->
                    send_error(<<"用户不存在">>, State)
            end
    end.

save_and_send_direct(ToId, Content, State) ->
    UserId = maps:get(user_id, State),

    case chat_db:save_message(UserId, ToId, Content) of
        {ok, Timestamp} ->

            Payload = #{
                <<"type">> => <<"chat">>,
                <<"room">> => <<"direct">>,
                <<"from">> => UserId,
                <<"to">> => ToId,
                <<"message">> => Content,
                <<"timestamp">> => Timestamp
            },

            IsOnline = chat_registry:send_to(ToId, Payload),

            case IsOnline of
                true ->
                    send_json(#{
                        <<"type">> => <<"chat_sent">>,
                        <<"to">> => ToId,
                        <<"timestamp">> => Timestamp
                    }, State);

                false ->
                    send_json(#{
                        <<"type">> => <<"chat_queued">>,
                        <<"to">> => ToId,
                        <<"timestamp">> => Timestamp
                    }, State)
            end;

        {error, Reason} ->
            io:format("[WS] 单聊保存失败: ~p~n", [Reason]),
            send_error(<<"消息保存失败">>, State)
    end.

%% ============================================================
%% 查询聊天历史
%% ============================================================

send_history(PeerId, Room, State) ->
    UserId = maps:get(user_id, State),

    Rows = chat_db:history(UserId, PeerId, 100),
    Messages = [
        #{
            <<"from">> => maps:get(from_id, M),
            <<"to">> => maps:get(to_id, M),
            <<"message">> => maps:get(message, M),
            <<"timestamp">> => maps:get(timestamp, M)
        }
        || M <- Rows
    ],

    send_json(#{
        <<"type">> => <<"history">>,
        <<"room">> => Room,
        <<"messages">> => Messages
    }, State).

%% ============================================================
%% JSON 回复
%% ============================================================

send_json(Data, State) ->
    {reply, {text, jsx:encode(Data)}, State}.

send_error(Message, State) ->
    send_json(#{
        <<"type">> => <<"error">>,
        <<"msg">> => Message
    }, State).

%% ============================================================
%% 接收其他 WebSocket 进程发来的消息
%% ============================================================

websocket_info({ws_send, Data}, State) ->
    {reply, {text, jsx:encode(Data)}, State};

websocket_info(_Info, State) ->
    {ok, State}.

%% ============================================================
%% 连接断开
%% ============================================================

terminate(Reason, _Req, State) ->
    case State of
        #{user_id := UserId} ->
            chat_registry:unregister(UserId),
            io:format(
                "[WS] 用户下线: ~s, Reason=~p~n",
                [UserId, Reason]
            );

        _ ->
            ok
    end,

    ok.