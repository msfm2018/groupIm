-module(upload_handler).
-behaviour(cowboy_handler).

%% POST /upload?token=xxx   multipart/form-data，字段名 file
%% 成功返回 {"code":0,"url":"/files/xxxx.jpg","kind":"image"|"video","size":123}

-export([init/2, upload_dir/0, ext_info/1]).

-define(MAX_SIZE, 104857600).   %% 100 MB

%% ------------------------------------------------------------
%% 文件保存目录（相对于启动目录的 uploads/）
%% ------------------------------------------------------------
upload_dir() ->
    Dir = filename:absname("uploads"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% 允许的扩展名 -> {类型, Content-Type}
%% 类型：image | video | audio | file
ext_info(Ext) ->
    case lists:keyfind(Ext, 1, types()) of
        {_, Kind, Mime} -> {Kind, Mime};
        false -> error
    end.

types() ->
    [
        %% 图片
        {<<".jpg">>,  image, <<"image/jpeg">>},
        {<<".jpeg">>, image, <<"image/jpeg">>},
        {<<".png">>,  image, <<"image/png">>},
        {<<".gif">>,  image, <<"image/gif">>},
        {<<".webp">>, image, <<"image/webp">>},
        {<<".bmp">>,  image, <<"image/bmp">>},
        %% 视频
        {<<".mp4">>,  video, <<"video/mp4">>},
        {<<".m4v">>,  video, <<"video/mp4">>},
        {<<".mov">>,  video, <<"video/quicktime">>},
        {<<".webm">>, video, <<"video/webm">>},
        {<<".mkv">>,  video, <<"video/x-matroska">>},
        {<<".avi">>,  video, <<"video/x-msvideo">>},
        %% 音频（语音消息）
        {<<".m4a">>,  audio, <<"audio/mp4">>},
        {<<".aac">>,  audio, <<"audio/aac">>},
        {<<".mp3">>,  audio, <<"audio/mpeg">>},
        {<<".wav">>,  audio, <<"audio/wav">>},
        {<<".ogg">>,  audio, <<"audio/ogg">>},
        {<<".opus">>, audio, <<"audio/ogg">>},
        %% 普通文件
        {<<".pdf">>,  file, <<"application/pdf">>},
        {<<".doc">>,  file, <<"application/msword">>},
        {<<".docx">>, file, <<"application/vnd.openxmlformats-officedocument.wordprocessingml.document">>},
        {<<".xls">>,  file, <<"application/vnd.ms-excel">>},
        {<<".xlsx">>, file, <<"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet">>},
        {<<".ppt">>,  file, <<"application/vnd.ms-powerpoint">>},
        {<<".pptx">>, file, <<"application/vnd.openxmlformats-officedocument.presentationml.presentation">>},
        {<<".txt">>,  file, <<"text/plain; charset=utf-8">>},
        {<<".csv">>,  file, <<"text/csv; charset=utf-8">>},
        {<<".zip">>,  file, <<"application/zip">>},
        {<<".rar">>,  file, <<"application/vnd.rar">>},
        {<<".7z">>,   file, <<"application/x-7z-compressed">>}
    ].

%% ------------------------------------------------------------
init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Req = cowboy_req:reply(204, cors_headers(), Req0),
            {ok, Req, State};
        <<"POST">> ->
            handle_upload(Req0, State);
        _ ->
            reply(Req0, 405, #{<<"code">> => 1,
                               <<"msg">> => <<"Method Not Allowed">>}, State)
    end.

handle_upload(Req0, State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Token = proplists:get_value(<<"token">>, Qs, undefined),
    case chat_db:authenticate(Token) of
        {ok, _UserId} ->
            try
                receive_file(Req0, State)
            catch
                Class:Reason ->
                    io:format("[UPLOAD] 异常: ~p:~p~n", [Class, Reason]),
                    reply(Req0, 400, #{<<"code">> => 1,
                                       <<"msg">> => <<"上传失败"/utf8>>}, State)
            end;
        _ ->
            reply(Req0, 401, #{<<"code">> => 1,
                               <<"msg">> => <<"Token 无效，请重新登录"/utf8>>}, State)
    end.

receive_file(Req0, State) ->
    case cowboy_req:read_part(Req0) of
        {ok, Headers, Req1} ->
            case cow_multipart:form_data(Headers) of
                {file, <<"file">>, Filename, _ContentType} ->
                    save_file(Filename, Req1, State);
                _ ->
                    reply(Req1, 400, #{<<"code">> => 1,
                                       <<"msg">> => <<"缺少 file 字段"/utf8>>}, State)
            end;
        {done, Req1} ->
            reply(Req1, 400, #{<<"code">> => 1,
                               <<"msg">> => <<"没有收到文件"/utf8>>}, State)
    end.

save_file(Filename, Req1, State) ->
    Ext = string:lowercase(filename:extension(Filename)),
    case ext_info(Ext) of
        error ->
            reply(Req1, 415, #{<<"code">> => 1,
                               <<"msg">> => <<"不支持的文件类型"/utf8>>}, State);
        {Kind, _Mime} ->
            Name = <<(random_hex())/binary, Ext/binary>>,
            Path = filename:join(upload_dir(), binary_to_list(Name)),
            {ok, Io} = file:open(Path, [write, binary, raw]),
            Result = stream_part(Req1, Io, 0),
            ok = file:close(Io),
            case Result of
                {ok, Size, Req2} ->
                    io:format("[UPLOAD] ~s (~p bytes)~n", [Name, Size]),
                    reply(Req2, 200, #{
                        <<"code">> => 0,
                        <<"url">> => <<"/files/", Name/binary>>,
                        <<"kind">> => atom_to_binary(Kind, utf8),
                        <<"size">> => Size
                    }, State);
                {too_large, Req2} ->
                    file:delete(Path),
                    reply(Req2, 413, #{<<"code">> => 1,
                                       <<"msg">> => <<"文件不能超过 100MB"/utf8>>}, State)
            end
    end.

%% 流式写盘，不把整个文件放进内存
stream_part(Req0, Io, Size0) ->
    case cowboy_req:read_part_body(Req0, #{length => 1048576}) of
        {Status, Chunk, Req1} when Status =:= ok; Status =:= more ->
            Size = Size0 + byte_size(Chunk),
            if
                Size > ?MAX_SIZE ->
                    {too_large, Req1};
                true ->
                    ok = file:write(Io, Chunk),
                    case Status of
                        ok   -> {ok, Size, Req1};
                        more -> stream_part(Req1, Io, Size)
                    end
            end
    end.

random_hex() ->
    Bin = crypto:strong_rand_bytes(16),
    list_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"*">>
    }.

reply(Req, Status, Map, State) ->
    Req2 = cowboy_req:reply(Status, maps:merge(cors_headers(), #{
        <<"content-type">> => <<"application/json; charset=utf-8">>
    }), jsx:encode(Map), Req),
    {ok, Req2, State}.
