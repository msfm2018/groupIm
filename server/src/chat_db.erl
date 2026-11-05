-module(chat_db).

-export([
    start/0,
    login/2,
    register/3,
    authenticate/1,
    get_friends/1,
    get_user/1,
    add_friend/2,
    are_friends/2,
    save_message/3,
    history/3
]).

%% Mnesia 表：
%% users    用户信息
%% tokens   登录 Token
%% friends  双向好友关系
%% messages 聊天记录

start() ->
    application:ensure_all_started(crypto),
    create_schema(),
    case application:ensure_all_started(mnesia) of
        {ok, _} ->
            create_tables();
        {error, {mnesia, {already_started, mnesia}}} ->
            create_tables();
        {error, Reason} ->
            {error, {start_mnesia_failed, Reason}}
    end.

create_schema() ->
    case mnesia:create_schema([node()]) of
        ok ->
            ok;
        {error, {_, {already_exists, _}}} ->
            ok;
        {error, {already_exists, _}} ->
            ok;
        {error, Reason} ->
            %% 已存在的 schema 在不同 OTP 版本中可能有不同错误包装。
            case io_lib:format("~p", [Reason]) of
                Text ->
                    case string:find(lists:flatten(Text), "already_exists") of
                        nomatch -> erlang:error({create_schema_failed, Reason});
                        _ -> ok
                    end
            end
    end.

create_tables() ->
    Tables = [
        {users, [id, username, password_hash, nickname]},
        {tokens, [token, user_id, created_at]},
        {friends, [id, user_id, friend_id, created_at]},
        {messages, [id, from_id, to_id, content, timestamp]}
    ],
    lists:foreach(fun create_table/1, Tables),
    case mnesia:wait_for_tables([users, tokens, friends, messages], 30000) of
        ok ->
            seed(),
            ok;
        {timeout, BadTables} ->
            {error, {mnesia_tables_timeout, BadTables}};
        {error, Reason} ->
            {error, {mnesia_tables_failed, Reason}}
    end.

create_table({Table, Attributes}) ->
    case mnesia:create_table(Table, [
        {attributes, Attributes},
        {disc_copies, [node()]}
    ]) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, Table}} ->
            ok;
        {aborted, Reason} ->
            erlang:error({create_table_failed, Table, Reason})
    end.

seed() ->
    ensure_user(<<"admin">>, <<"123456">>, <<"管理员">>),
    ensure_user(<<"alice">>, <<"123456">>, <<"Alice">>),
    ensure_user(<<"bob">>, <<"123456">>, <<"Bob">>),
    add_friend(<<"admin">>, <<"alice">>),
    add_friend(<<"admin">>, <<"bob">>),
    add_friend(<<"alice">>, <<"bob">>),
    ok.

ensure_user(UserId, Password, Nickname) ->
    Hash = password_hash(Password),
    _ = mnesia:transaction(fun() ->
        case mnesia:read(users, UserId, write) of
            [] ->
                mnesia:write({users, UserId, UserId, Hash, Nickname});
            _ ->
                ok
        end
    end),
    ok.

password_hash(Password) ->
    crypto:hash(sha256, Password).

login(Username, Password)
        when is_binary(Username), is_binary(Password) ->
    Token = base64:encode(crypto:strong_rand_bytes(32)),
    Now = erlang:system_time(millisecond),
    Hash = password_hash(Password),
    case mnesia:transaction(fun() ->
        case mnesia:read(users, Username, read) of
            [{users, UserId, _Name, Hash, Nickname}] ->
                mnesia:write({tokens, Token, UserId, Now}),
                {ok, UserId, Nickname, Token};
            _ ->
                {error, <<"账号或密码错误">>}
        end
    end) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, iolist_to_binary(io_lib:format("数据库错误: ~p", [Reason]))}
    end;
login(_, _) ->
    {error, <<"用户名或密码格式错误">>}.

%% 注册新用户。用户名只允许 3-20 位英文字母、数字和下划线。
%% 密码至少 6 位；昵称为 1-30 个 UTF-8 字节以内的文本（此处按字节限制）。
register(Username, Password, Nickname)
        when is_binary(Username), is_binary(Password), is_binary(Nickname) ->
    ValidUsername = re:run(Username, <<"^[A-Za-z0-9_]{3,20}$">>,
                           [{capture, none}]) =:= match,
    ValidPassword = byte_size(Password) >= 6 andalso byte_size(Password) =< 64,
    ValidNickname = byte_size(Nickname) >= 1 andalso byte_size(Nickname) =< 90,
    case {ValidUsername, ValidPassword, ValidNickname} of
        {false, _, _} -> {error, <<"用户名需为 3-20 位字母、数字或下划线">>};
        {_, false, _} -> {error, <<"密码长度需为 6-64 位">>};
        {_, _, false} -> {error, <<"昵称不能为空且不能超过 30 个汉字左右">>};
        {true, true, true} ->
            Hash = password_hash(Password),
            case mnesia:transaction(fun() ->
                case mnesia:read(users, Username, write) of
                    [] ->
                        mnesia:write({users, Username, Username, Hash, Nickname}),
                        {ok, Username, Nickname};
                    _ ->
                        {error, <<"用户名已存在">>}
                end
            end) of
                {atomic, Result} -> Result;
                {aborted, Reason} ->
                    {error, iolist_to_binary(io_lib:format("注册失败: ~p", [Reason]))}
            end
    end;
register(_, _, _) ->
    {error, <<"注册参数格式错误">>}.

authenticate(Token) when is_binary(Token) ->
    case mnesia:transaction(fun() ->
        case mnesia:read(tokens, Token, read) of
            [{tokens, Token, UserId, _CreatedAt}] -> {ok, UserId};
            [] -> {error, invalid_token}
        end
    end) of
        {atomic, Result} -> Result;
        {aborted, _} -> {error, database_error}
    end;
authenticate(_) ->
    {error, invalid_token}.

get_user(UserId) ->
    case mnesia:transaction(fun() ->
        case mnesia:read(users, UserId, read) of
            [{users, Id, Username, _Hash, Nickname}] ->
                {ok, #{user_id => Id, username => Username, nickname => Nickname}};
            [] ->
                {error, not_found}
        end
    end) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

get_friends(UserId) ->
    case mnesia:transaction(fun() ->
        FriendIds = mnesia:foldl(
            fun
                ({friends, _Id, UserId0, FriendId, _At}, Acc)
                        when UserId0 =:= UserId ->
                    [FriendId | Acc];
                (_, Acc) ->
                    Acc
            end,
            [],
            friends
        ),
        [begin
            case mnesia:read(users, FriendId, read) of
                [{users, Id, _Username, _Hash, Nickname}] ->
                    #{user_id => Id, nickname => Nickname};
                [] ->
                    #{user_id => FriendId, nickname => FriendId}
            end
        end || FriendId <- lists:usort(FriendIds)]
    end) of
        {atomic, Result} -> Result;
        {aborted, _} -> []
    end.

add_friend(UserId, FriendId)
        when is_binary(UserId), is_binary(FriendId), UserId =/= FriendId ->
    Now = erlang:system_time(millisecond),
    case mnesia:transaction(fun() ->
        case {
            mnesia:read(users, UserId, read),
            mnesia:read(users, FriendId, read)
        } of
            {[_], [_]} ->
                mnesia:write({friends, {UserId, FriendId}, UserId, FriendId, Now}),
                mnesia:write({friends, {FriendId, UserId}, FriendId, UserId, Now}),
                ok;
            {[], _} -> {error, user_not_found};
            {_, []} -> {error, friend_not_found}
        end
    end) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end;
add_friend(_, _) ->
    {error, invalid_user_id}.

are_friends(UserId, FriendId) ->
    case mnesia:transaction(fun() ->
        mnesia:read(friends, {UserId, FriendId}, read) =/= []
    end) of
        {atomic, Result} -> Result;
        _ -> false
    end.

save_message(FromId, ToId, Content)
        when is_binary(FromId), is_binary(ToId), is_binary(Content) ->
    Id = crypto:strong_rand_bytes(16),
    Timestamp = erlang:system_time(millisecond),
    case mnesia:transaction(fun() ->
        mnesia:write({messages, Id, FromId, ToId, Content, Timestamp}),
        Timestamp
    end) of
        {atomic, SavedAt} -> {ok, SavedAt};
        {aborted, Reason} -> {error, Reason}
    end.


history(UserId, FriendId, Limit)
        when is_integer(Limit), Limit > 0 ->

    case mnesia:transaction(fun() ->
        Rows = mnesia:foldl(
            fun
                %% 群聊：查询所有发送到公共聊天室的消息
                ({messages, _Id, _FromId, <<"__group__">>, _Content, _Ts} = Row, Acc)
                        when FriendId =:= <<"__group__">> ->
                    [Row | Acc];

                %% 单聊：查询双方互相发送的消息
                ({messages, _Id, FromId, ToId, _Content, _Ts} = Row, Acc)
                        when FriendId =/= <<"__group__">>,
                             ((FromId =:= UserId andalso ToId =:= FriendId)
                              orelse
                              (FromId =:= FriendId andalso ToId =:= UserId)) ->
                    [Row | Acc];

                (_, Acc) ->
                    Acc
            end,
            [],
            messages
        ),

        Sorted = lists:sort(
            fun(
                {messages, _, _, _, _, A},
                {messages, _, _, _, _, B}
            ) ->
                A =< B
            end,
            Rows
        ),

        LastRows = lists:sublist(
            lists:reverse(Sorted),
            Limit
        ),

        [
            #{
                from_id => From,
                to_id => To,
                message => Content,
                timestamp => Ts
            }
            ||
            {messages, _Id, From, To, Content, Ts}
            <- lists:reverse(LastRows)
        ]

    end) of
        {atomic, Result} ->
            Result;

        {aborted, Reason} ->
            io:format("[DB] history error: ~p~n", [Reason]),
            []
    end;

history(_, _, _) ->
    [].
