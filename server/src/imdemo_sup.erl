-module(imdemo_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% chat_registry 使用 OTP pg + ETS，无需独立进程
    Children = [],
    {ok, {
        #{strategy => one_for_one, intensity => 5, period => 10},
        Children
    }}.