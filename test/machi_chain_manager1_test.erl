%% -------------------------------------------------------------------
%%
%% Machi: a small village of replicated files
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(machi_chain_manager1_test).

-include("machi.hrl").
-include("machi_projection.hrl").

-define(MGR, machi_chain_manager1).

-define(D(X), io:format(user, "~s ~p\n", [??X, X])).
-define(Dw(X), io:format(user, "~s ~w\n", [??X, X])).
-define(FLU_C,  machi_flu1_client).
-define(FLU_PC, machi_proxy_flu1_client).

-export([]).

-ifdef(TEST).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
%% -include_lib("eqc/include/eqc_statem.hrl").
-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).
-endif.

-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

%% @doc Create a summary report of all of the *private* projections of
%%      each of the FLUs in the chain, and create a summary for each
%%      epoch number.
%%
%% Report format: list({EpochNumber::non_neg_integer(), Report::rpt()})
%%        rpt(): {ok_disjoint | bummer_NOT_DISJOINT, agree_list()}
%% agree_list(): list(agree())
%%      agree(): {agreed_membership, UPIandRepairing()} |
%%               {not_agreed, ......TODO LEFT OFF HERE
%%
%% Example:
%% TODO LEFT OFF HERE

unanimous_report(Namez) ->
    UniquePrivateEs =
        lists:usort(lists:flatten(
                      [element(2, ?FLU_PC:list_all_projections(FLU, private)) ||
                          {_FLUName, FLU} <- Namez])),
    [{Epoch, unanimous_report(Epoch, Namez)} || Epoch <- UniquePrivateEs,
                                                Epoch /= 0].

unanimous_report(Epoch, Namez) ->
    FLU_Projs = [{FLUName,
                  case ?FLU_PC:read_projection(FLU, private, Epoch) of
                      {ok, T} ->
                          machi_chain_manager1:inner_projection_or_self(T);
                      _Else ->
                          not_in_this_epoch
                  end} || {FLUName, FLU} <- Namez],
    unanimous_report2(FLU_Projs).

unanimous_report2(FLU_Projs) ->
    ProjsSumms = [{FLU, if is_tuple(P) ->
                                Summ = machi_projection:make_summary(P),
                                lists:flatten(io_lib:format("~w", [Summ]));
                           is_atom(P) ->
                                P
                        end} || {FLU, P} <- FLU_Projs],
    UPI_R_Sums = [{Proj#projection_v1.upi, Proj#projection_v1.repairing,
                   Proj#projection_v1.epoch_csum} ||
                     {_FLUname, Proj} <- FLU_Projs,
                     is_record(Proj, projection_v1)],
    UniqueUPIs = lists:usort([UPI || {UPI, _Repairing, _CSum} <- UPI_R_Sums]),
    Res =
        [begin
             case lists:usort([CSum || {U, _Repairing, CSum} <- UPI_R_Sums,
                                       U == UPI]) of
                 [_1CSum] ->
                     %% Yay, there's only 1 checksum.  Let's check
                     %% that all FLUs are in agreement.
                     {UPI, Repairing, _CSum} =
                         lists:keyfind(UPI, 1, UPI_R_Sums),
                     Tmp = [{FLU, case proplists:get_value(FLU, FLU_Projs) of
                                      P when is_record(P, projection_v1) ->
                                          P#projection_v1.epoch_csum;
                                      Else ->
                                          Else
                                  end} || FLU <- UPI ++ Repairing],
                     case lists:usort([CSum || {_FLU, CSum} <- Tmp]) of
                         [_] ->
                             {agreed_membership, {UPI, Repairing}};
                         _Else2 ->
                             {not_agreed, ProjsSumms}
                     end;
                 _Else ->
                     {not_agreed, [checksum_disagreement|ProjsSumms]}
             end
         end || UPI <- UniqueUPIs],
    AgreedResUPI_Rs = [UPI++Repairing ||
                          {agreed_membership, {UPI, Repairing}} <- Res],
    Tag = case lists:usort(lists:flatten(AgreedResUPI_Rs)) ==
               lists:sort(lists:flatten(AgreedResUPI_Rs)) of
              true ->
                  ok_disjoint;
              false ->
                  bummer_NOT_DISJOINT
          end,
    {Tag, Res}.

all_reports_are_disjoint(Report) ->
    [] == [X || {_Epoch, Tuple}=X <- Report,
                element(1, Tuple) /= ok_disjoint].

extract_chains_relative_to_flu(FLU, Report) ->
    {FLU, [{Epoch, UPI, Repairing} ||
              {Epoch, {ok_disjoint, Es}} <- Report,
              {agreed_membership, {UPI, Repairing}} <- Es,
              lists:member(FLU, UPI) orelse lists:member(FLU, Repairing)]}.

chain_to_projection(MyName, Epoch, UPI_list, Repairing_list, All_list) ->
    MemberDict = orddict:from_list([{FLU, #p_srvr{name=FLU}} ||
                                       FLU <- All_list]),
    machi_projection:new(Epoch, MyName, MemberDict,
                         All_list -- (UPI_list ++ Repairing_list),
                         UPI_list, Repairing_list, [{artificial_by, ?MODULE}]).

-ifndef(PULSE).

simple_chain_state_transition_is_sane_test_() ->
    {timeout, 300, fun() -> simple_chain_state_transition_is_sane_test2() end}.

simple_chain_state_transition_is_sane_test2() ->
    %% All: A list of all FLUS for a particular test
    %% UPI1: some combination of All that represents UPI1
    %% Repair1: Some combination of (All -- UP1) that represents Repairing1
    %% ... then we test check_simple_chain_state_transition_is_sane() with all
    %% possible UPI1 and Repair1.
    [true = check_simple_chain_state_transition_is_sane(UPI1, Repair1) ||
        %% The five elements below runs on my MacBook Pro in about 4.8 seconds
        %% All <- [ [a], [a,b], [a,b,c], [a,b,c,d], [a,b,c,d,e] ],
        All <- [ [a], [a,b], [a,b,c], [a,b,c,d] ],
        UPI1 <- machi_util:combinations(All),
        Repair1 <- machi_util:combinations(All -- UPI1)].

%% Given a UPI1 and Repair1 list, we calculate all possible good UPI2
%% lists.  For all good {UPI1, Repair1} -> UPI2 transitions, then the
%% simple_chain_state_transition_is_sane() function must be true.  For
%% all other UPI2 transitions, simple_chain_state_transition_is_sane()
%% must be false.
%%
%% We include adding an extra possible participant, 'bogus', to the
%% list of all possible UPI2 transitions, just to demonstrate that
%% adding an extra element/participant/thingie is never sane.

check_simple_chain_state_transition_is_sane([], []) ->
    true;
check_simple_chain_state_transition_is_sane(UPI1, Repair1) ->
    Good_UPI2s = [ X ++ Y || X <- machi_util:ordered_combinations(UPI1),
                             Y <- machi_util:ordered_combinations(Repair1)],
    All_UPI2s = machi_util:combinations(lists:usort(UPI1 ++ Repair1) ++
                                            [bogus]),

    [true = ?MGR:simple_chain_state_transition_is_sane(UPI1, Repair1, UPI2) ||
        UPI2 <- Good_UPI2s],
    [false = ?MGR:simple_chain_state_transition_is_sane(UPI1, Repair1, UPI2) ||
        UPI2 <- (All_UPI2s -- Good_UPI2s)],

    true.

-ifdef(EQC).

prop_compare_legacy_with_v2_chain_transition_check() ->
    %% ?FORALL(All, nonempty(list([a,b,c,d,e])),
    ?FORALL(All, non_empty(some([a,b,c])),
    ?FORALL({Author1, UPI1, Repair1x, Author2, UPI2, Repair2x},
         {elements(All),some(All),some(All),elements(All),some(All),some(All)},
    ?IMPLIES(length(lists:usort(UPI1 ++ Repair1x)) > 0 andalso
             length(lists:usort(UPI2 ++ Repair2x)) > 0,
    begin
        MembersDict = orddict:from_list([{X, #p_srvr{name=X}} || X <- All]),
        Repair1 = Repair1x -- UPI1,
        Down1 = All -- (UPI1 ++ Repair1),
        Repair2 = Repair2x -- UPI2,
        Down2 = All -- (UPI2 ++ Repair2),
        P1 = machi_projection:new(1, Author1, MembersDict,
                                  Down1, UPI1, Repair1, []),
        P2 = machi_projection:new(2, Author2, MembersDict,
                                  Down2, UPI2, Repair2, []),
        Old_res = chain_mgr_legacy:projection_transition_is_sane(
                       P1, P2, Author1, false),
        Old_p = case Old_res of true -> true;
                                _    -> false
                end,
        New_res = ?MGR:chain_state_transition_is_sane(Author1, UPI1, Repair1,
                                                      Author2, UPI2),
        New_p = New_res,
        (catch ets:insert(count, {{Author1, UPI1, Repair1, Author2, UPI2, Repair2}, true})),
        ?WHENFAIL(io:format(user,
                            "Old_res (~p): ~p\nNew_res: ~p (why line ~p)\n",
                            [catch get(why1), Old_res, New_res, catch get(why2)]),
                  Old_p == New_p)
    end))).

some(L) ->
    ?LET(L2, list(oneof(L)),
         dedupe(L2)).

dedupe(L) ->
    dedupe(L, []).

dedupe([H|T], Seen) ->
    case lists:member(H, Seen) of
        false ->
            [H|dedupe(T, [H|Seen])];
        true ->
            dedupe(T, Seen)
    end;
dedupe([], _) ->
    [].

make_prop_ets() ->
    ets:new(count, [named_table, set, public]).

-endif. % EQC

smoke0_test() ->
    {ok, _} = machi_partition_simulator:start_link({1,2,3}, 50, 50),
    Host = "localhost",
    TcpPort = 6623,
    {ok, FLUa} = machi_flu1:start_link([{a,TcpPort,"./data.a"}]),
    Pa = #p_srvr{name=a, address=Host, port=TcpPort},
    Members_Dict = machi_projection:make_members_dict([Pa]),
    %% Egadz, more racing on startup, yay.  TODO fix.
    timer:sleep(1),
    {ok, FLUaP} = ?FLU_PC:start_link(Pa),
    {ok, M0} = ?MGR:start_link(a, Members_Dict, [{active_mode, false}]),
    _SockA = machi_util:connect(Host, TcpPort),
    try
        pong = ?MGR:ping(M0)
    after
        ok = ?MGR:stop(M0),
        ok = machi_flu1:stop(FLUa),
        ok = ?FLU_PC:quit(FLUaP),
        ok = machi_partition_simulator:stop()
    end.

smoke1_test() ->
    machi_partition_simulator:start_link({1,2,3}, 100, 0),
    TcpPort = 62777,
    FluInfo = [{a,TcpPort+0,"./data.a"}, {b,TcpPort+1,"./data.b"}, {c,TcpPort+2,"./data.c"}],
    P_s = [#p_srvr{name=Name, address="localhost", port=Port} ||
              {Name,Port,_Dir} <- FluInfo],

    [machi_flu1_test:clean_up_data_dir(Dir) || {_,_,Dir} <- FluInfo],
    FLUs = [element(2, machi_flu1:start_link([{Name,Port,Dir}])) ||
               {Name,Port,Dir} <- FluInfo],
    MembersDict = machi_projection:make_members_dict(P_s),
    {ok, M0} = ?MGR:start_link(a, MembersDict, [{active_mode,false}]),
    try
        {ok, P1} = ?MGR:test_calc_projection(M0, false),
        % DERP! Check for race with manager's proxy vs. proj listener
        case ?MGR:test_read_latest_public_projection(M0, false) of
            {error, partition} -> timer:sleep(500);
            _                  -> ok
        end,
        {local_write_result, ok,
         {remote_write_results, [{b,ok},{c,ok}]}} =
            ?MGR:test_write_public_projection(M0, P1),
        {unanimous, P1, Extra1} = ?MGR:test_read_latest_public_projection(M0, false),

        ok
    after
        ok = ?MGR:stop(M0),
        [ok = machi_flu1:stop(X) || X <- FLUs],
        ok = machi_partition_simulator:stop()
    end.

nonunanimous_setup_and_fix_test() ->
    machi_partition_simulator:start_link({1,2,3}, 100, 0),
    TcpPort = 62877,
    FluInfo = [{a,TcpPort+0,"./data.a"}, {b,TcpPort+1,"./data.b"}],
    P_s = [#p_srvr{name=Name, address="localhost", port=Port} ||
              {Name,Port,_Dir} <- FluInfo],
    
    [machi_flu1_test:clean_up_data_dir(Dir) || {_,_,Dir} <- FluInfo],
    FLUs = [element(2, machi_flu1:start_link([{Name,Port,Dir}])) ||
               {Name,Port,Dir} <- FluInfo],
    [Proxy_a, Proxy_b] = Proxies =
        [element(2,?FLU_PC:start_link(P)) || P <- P_s],
    MembersDict = machi_projection:make_members_dict(P_s),
    XX = [],
    %% XX = [{private_write_verbose,true}],
    {ok, Ma} = ?MGR:start_link(a, MembersDict, [{active_mode, false}]++XX),
    {ok, Mb} = ?MGR:start_link(b, MembersDict, [{active_mode, false}]++XX),
    try
        {ok, P1} = ?MGR:test_calc_projection(Ma, false),

        P1a = machi_projection:update_checksum(
                 P1#projection_v1{down=[b], upi=[a], dbg=[{hackhack, ?LINE}]}),
        P1b = machi_projection:update_checksum(
                 P1#projection_v1{author_server=b, creation_time=now(),
                                  down=[a], upi=[b], dbg=[{hackhack, ?LINE}]}),
        %% Scribble different projections
        ok = ?FLU_PC:write_projection(Proxy_a, public, P1a),
        ok = ?FLU_PC:write_projection(Proxy_b, public, P1b),

        %% ?D(x),
        {not_unanimous,_,_}=_XX = ?MGR:test_read_latest_public_projection(
                                     Ma, false),
        %% ?Dw(_XX),
        {not_unanimous,_,_}=_YY = ?MGR:test_read_latest_public_projection(
                                     Ma, true),
        %% The read repair here doesn't automatically trigger the creation of
        %% a new projection (to try to create a unanimous projection).  So
        %% we expect nothing to change when called again.
        {not_unanimous,_,_}=_YY = ?MGR:test_read_latest_public_projection(
                                     Ma, true),

        {now_using, _, EpochNum_a} = ?MGR:test_react_to_env(Ma),
        {no_change, _, EpochNum_a} = ?MGR:test_react_to_env(Ma),
        {unanimous,P2,_E2} = ?MGR:test_read_latest_public_projection(Ma, false),
        {ok, P2pa} = ?FLU_PC:read_latest_projection(Proxy_a, private),
        P2 = P2pa#projection_v1{dbg2=[]},

        %% FLUb should have nothing written to private because it hasn't
        %% reacted yet.
        {error, not_written} = ?FLU_PC:read_latest_projection(Proxy_b, private),

        %% Poke FLUb to react ... should be using the same private proj
        %% as FLUa.
        {now_using, _, EpochNum_a} = ?MGR:test_react_to_env(Mb),
        {ok, P2pb} = ?FLU_PC:read_latest_projection(Proxy_b, private),
        P2 = P2pb#projection_v1{dbg2=[]},

        ok
    after
        ok = ?MGR:stop(Ma),
        ok = ?MGR:stop(Mb),
        [ok = ?FLU_PC:quit(X) || X <- Proxies],
        [ok = machi_flu1:stop(X) || X <- FLUs],
        ok = machi_partition_simulator:stop()
    end.

foo_TODO_UNFINISHED_KEEP_PERHAPS_unanimous_report_test() ->
    TcpPort = 63877,
    FluInfo = [{a,TcpPort+0,"./data.a"}, {b,TcpPort+1,"./data.b"}],
    P_s = [#p_srvr{name=Name, address="localhost", port=Port} ||
              {Name,Port,_Dir} <- FluInfo],
    MembersDict = machi_projection:make_members_dict(P_s),

    E5 = 5,
    UPI5 = [a,b],
    Rep5 = [],
    P5 = machi_projection:new(E5, a, MembersDict, [], UPI5, Rep5, []),
    {ok_disjoint, [{agreed_membership, {UPI5, Rep5}}]} =
        unanimous_report2([{a, P5}, {b, P5}]),
    {ok_disjoint, [{not_agreed, _}]} =
        unanimous_report2([{a, not_in_this_epoch}, {b, P5}]),
    {ok_disjoint, [{not_agreed, _}]} =
        unanimous_report2([{a, P5}, {b, not_in_this_epoch}]),

    P5_other_csum = machi_projection:update_checksum(
                    P5#projection_v1{author_server=b}),
    {ok_disjoint, [{not_agreed, _}]} =
        unanimous_report2([{a, P5}, {b, P5_other_csum}]),

    UPI5_b = [a],
    Rep5_b = [b],
    P5_b = machi_projection:new(E5, b, MembersDict, [], UPI5_b, Rep5_b, []),
    XX =
        unanimous_report2([{a, P5}, {b, P5_b}]),

    io:format(user, "\nXX ~p\n", [XX]).

-endif. % !PULSE
-endif. % TEST
