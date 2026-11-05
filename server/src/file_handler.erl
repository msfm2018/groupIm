-module(file_handler).
-behaviour(cowboy_handler).

%% GET /files/:name  读取已上传的图片/视频，支持 Range（视频拖动进度、iOS 播放需要）

-include_lib("kernel/include/file.hrl").

-export([init/2]).

init(Req0, State) ->
    Name = cowboy_req:binding(name, Req0),
    case safe_name(Name) of
        false ->
            not_found(Req0, State);
        true ->
            Ext = filename:extension(Name),
            Path = filename:join(upload_handler:upload_dir(), binary_to_list(Name)),
            case {upload_handler:ext_info(Ext), file:read_file_info(Path)} of
                {{_Kind, Mime}, {ok, #file_info{type = regular, size = Size}}}
                        when Size > 0 ->
                    serve(Req0, Path, Size, Mime, State);
                _ ->
                    not_found(Req0, State)
            end
    end.

%% 文件名只允许 32 位 hex + 扩展名，防止路径穿越
safe_name(Name) when is_binary(Name) ->
    re:run(Name, <<"^[0-9a-f]{32}\\.[a-z0-9]{2,5}$">>, [{capture, none}]) =:= match;
safe_name(_) ->
    false.

serve(Req0, Path, Size, Mime, State) ->
    Base0 = #{
        <<"content-type">> => Mime,
        <<"accept-ranges">> => <<"bytes">>,
        <<"access-control-allow-origin">> => <<"*">>,
        <<"cache-control">> => <<"public, max-age=31536000, immutable">>,
        <<"x-content-type-options">> => <<"nosniff">>
    },
    Base = maps:merge(Base0, disposition(Req0)),
    case parse_range(cowboy_req:header(<<"range">>, Req0), Size) of
        full ->
            Req = cowboy_req:reply(200, Base, {sendfile, 0, Size, Path}, Req0),
            {ok, Req, State};
        {Start, End} ->
            Len = End - Start + 1,
            Range = iolist_to_binary(io_lib:format("bytes ~B-~B/~B", [Start, End, Size])),
            Req = cowboy_req:reply(206, Base#{<<"content-range">> => Range},
                                   {sendfile, Start, Len, Path}, Req0),
            {ok, Req, State};
        unsatisfiable ->
            Range = iolist_to_binary(io_lib:format("bytes */~B", [Size])),
            Req = cowboy_req:reply(416, #{<<"content-range">> => Range}, Req0),
            {ok, Req, State}
    end.

%% 带 ?name=原文件名 时，以附件形式下载并使用原文件名
disposition(Req) ->
    case proplists:get_value(<<"name">>, cowboy_req:parse_qs(Req)) of
        N when is_binary(N), byte_size(N) > 0, byte_size(N) =< 200 ->
            #{<<"content-disposition">> =>
                  <<"attachment; filename*=UTF-8''", (cow_uri:urlencode(N))/binary>>};
        _ ->
            #{}
    end.

parse_range(undefined, _Size) ->
    full;
parse_range(<<"bytes=", Spec/binary>>, Size) ->
    try
        case binary:split(Spec, <<"-">>) of
            [<<>>, Suffix] ->
                N = binary_to_integer(Suffix),
                if N > 0 -> {max(0, Size - N), Size - 1};
                   true  -> unsatisfiable
                end;
            [S, <<>>] ->
                Start = binary_to_integer(S),
                if Start < Size -> {Start, Size - 1};
                   true         -> unsatisfiable
                end;
            [S, E] ->
                Start = binary_to_integer(S),
                End = min(binary_to_integer(E), Size - 1),
                if Start =< End -> {Start, End};
                   true         -> unsatisfiable
                end
        end
    catch
        _:_ -> full
    end;
parse_range(_, _Size) ->
    full.

not_found(Req0, State) ->
    Req = cowboy_req:reply(404, #{<<"content-type">> => <<"text/plain">>},
                           <<"Not Found">>, Req0),
    {ok, Req, State}.
