-module(chat_registry).

-export([
    ensure_started/0,
    register/2,
    unregister/1,
    broadcast/1,
    send_to/2,
    is_online/1,
    online_users/0
]).

-define(ONLINE_GROUP, imdemo_online).
-define(USER_GROUP, imdemo_user).
-define(ONLINE_ETS, imdemo_online_users).

%% ============================================================
%% 确保 ETS 已创建（应用启动时调用）
%% ============================================================

ensure_started() ->
    case ets:info(?ONLINE_ETS) of
        undefined ->
            ets:new(?ONLINE_ETS, [
                named_table,
                public,
                set,
                {read_concurrency, true}
            ]),
            ok;
        _ ->
            ok
    end.

%% ============================================================
%% 注册在线用户
%% ============================================================

register(UserId, Nickname)
        when is_binary(UserId), is_binary(Nickname) ->
    ensure_started(),
    WasOnline = is_online(UserId),

    ok = pg:join(?ONLINE_GROUP, self()),
    ok = pg:join({?USER_GROUP, UserId}, self()),

    ets:insert(?ONLINE_ETS, {UserId, Nickname}),

    case WasOnline of
        false ->
            broadcast(#{
                <<"type">> => <<"user_online">>,
                <<"user_id">> => UserId,
                <<"nickname">> => Nickname
            });
        true ->
            ok
    end,

    ok.

%% ============================================================
%% 用户是否在线
%% ============================================================

is_online(UserId) when is_binary(UserId) ->
    members({?USER_GROUP, UserId}) =/= [].

%% ============================================================
%% 当前所有在线用户 [{UserId, Nickname}, ...]
%% ============================================================

online_users() ->
    ensure_started(),
    ets:tab2list(?ONLINE_ETS).

%% ============================================================
%% 群聊广播
%% ============================================================

broadcast(Data) when is_map(Data) ->
    CurrentPid = self(),

    lists:foreach(
        fun(Pid) ->
            case Pid =:= CurrentPid of
                true ->
                    ok;
                false ->
                    Pid ! {ws_send, Data}
            end
        end,
        members(?ONLINE_GROUP)
    ),

    ok.

%% ============================================================
%% 单聊：发送给指定用户的全部在线连接
%% ============================================================

send_to(UserId, Data)
        when is_binary(UserId), is_map(Data) ->

    Pids = members({?USER_GROUP, UserId}),

    lists:foreach(
        fun(Pid) ->
            Pid ! {ws_send, Data}
        end,
        Pids
    ),

    Pids =/= [].

%% ============================================================
%% 注销在线用户
%% ============================================================

unregister(UserId) when is_binary(UserId) ->
    ensure_started(),
    UserPids = members({?USER_GROUP, UserId}),

    OtherOnline = lists:any(
        fun(Pid) -> Pid =/= self() end,
        UserPids
    ),

    _ = catch pg:leave({?USER_GROUP, UserId}, self()),
    _ = catch pg:leave(?ONLINE_GROUP, self()),

    case OtherOnline of
        false ->
            ets:delete(?ONLINE_ETS, UserId),
            broadcast(#{
                <<"type">> => <<"user_offline">>,
                <<"user_id">> => UserId
            });
        true ->
            ok
    end,

    ok.

%% ============================================================
%% 安全获取进程列表
%% ============================================================

members(Group) ->
    try
        pg:get_members(Group)
    catch
        _:_ ->
            []
    end.