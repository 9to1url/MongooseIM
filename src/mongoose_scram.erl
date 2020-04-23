-module(mongoose_scram).

-include("mongoose.hrl").
-include("scram.hrl").

% Core SCRAM functions
%% ejabberd doesn't implement SASLPREP, so we use the similar RESOURCEPREP instead
-export([
         salted_password/4,
         stored_key/2,
         server_key/2,
         server_signature/3,
         client_signature/3,
         client_key/2,
         client_proof_key/2]).

-export([
         enabled/1,
         can_login_with_configured_password_format/2,
         iterations/0,
         iterations/1,
         password_to_scram/2,
         password_to_scram/3,
         check_password/2,
         check_digest/4
        ]).

-export([serialize/1, deserialize/1]).

-export([scram_to_tuple/1, scram_record_to_map/1]).

-type sha_type() :: crypto:sha1() | crypto:sha2().

-type scram_tuple() :: { StoredKey :: binary(), ServerKey :: binary(),
                         Salt :: binary(), Iterations :: non_neg_integer() }.

-type scram_map() ::
    #{salt := binary(),
      iteration_count := non_neg_integer(),
      sha_key() := server_and_stored_key_type()}.

-type sha_key() :: sha | sha224 | sha256 | sha384 | sha512.

-type server_and_stored_key_type() :: #{server_key := binary(), stored_key := binary()}.

-type scram() :: #scram{}.

-export_type([scram_tuple/0, scram/0, scram_map/0]).

-define(SALT_LENGTH, 16).
-define(SCRAM_DEFAULT_ITERATION_COUNT, 4096).
-define(SCRAM_SERIAL_PREFIX, "==SCRAM==,").
-define(MULTI_SCRAM_SERIAL_PREFIX, "==MULTI_SCRAM==,").
-define(SCRAM_SHA_PREFIX, "===SHA1===").
-define(SCRAM_SHA224_PREFIX, "==SHA224==").
-define(SCRAM_SHA256_PREFIX, "==SHA256==").
-define(SCRAM_SHA384_PREFIX, "==SHA384==").
-define(SCRAM_SHA512_PREFIX, "==SHA512==").
-define(SCRAM_SHA1_PLUS_PREFIX, "=SHA1PLUS=").

-spec salted_password(sha_type(), binary(), binary(), non_neg_integer()) -> binary().
salted_password(Sha, Password, Salt, IterationCount) ->
    hi(Sha, jid:resourceprep(Password), Salt, IterationCount).

-spec client_key(sha_type(), binary()) -> binary().
client_key(Sha, SaltedPassword) ->
    crypto:hmac(Sha, SaltedPassword, <<"Client Key">>).

-spec stored_key(sha_type(), binary()) -> binary().
stored_key(Sha, ClientKey) -> crypto:hash(Sha, ClientKey).

-spec server_key(sha_type(), binary()) -> binary().
server_key(Sha, SaltedPassword) ->
    crypto:hmac(Sha, SaltedPassword, <<"Server Key">>).

-spec client_signature(sha_type(), binary(), binary()) -> binary().
client_signature(Sha, StoredKey, AuthMessage) ->
    crypto:hmac(Sha, StoredKey, AuthMessage).

-spec client_proof_key(binary(), binary()) -> binary().
client_proof_key(ClientProof, ClientSignature) ->
    mask(ClientProof, ClientSignature).

-spec server_signature(sha_type(), binary(), binary()) -> binary().
server_signature(Sha, ServerKey, AuthMessage) ->
    crypto:hmac(Sha, ServerKey, AuthMessage).

-spec hi(sha_type(), binary(), binary(), non_neg_integer()) -> binary().
hi(Sha, Password, Salt, IterationCount) ->
    U1 = crypto:hmac(Sha, Password, <<Salt/binary, 0, 0, 0, 1>>),
    mask(U1, hi_round(Sha, Password, U1, IterationCount - 1)).

-spec hi_round(sha_type(), binary(), binary(), non_neg_integer()) -> binary().
hi_round(Sha, Password, UPrev, 1) ->
    crypto:hmac(Sha, Password, UPrev);
hi_round(Sha, Password, UPrev, IterationCount) ->
    U = crypto:hmac(Sha, Password, UPrev),
    mask(U, hi_round(Sha, Password, U, IterationCount - 1)).

-spec mask(binary(), binary()) -> binary().
mask(Key, Data) ->
    KeySize = size(Key) * 8,
    <<A:KeySize>> = Key,
    <<B:KeySize>> = Data,
    C = A bxor B,
    <<C:KeySize>>.

enabled(Host) ->
    case ejabberd_auth:get_opt(Host, password_format) of
        scram -> true;
        {scram, _ScramSha} -> true;
        _ -> false
    end.

can_login_with_configured_password_format(Host, cyrsasl_scram_sha1) ->
    is_password_format_allowed(Host, sha);
can_login_with_configured_password_format(Host, cyrsasl_scram_sha1_plus) ->
    is_password_format_allowed(Host, sha);
can_login_with_configured_password_format(Host, cyrsasl_scram_sha224) ->
    is_password_format_allowed(Host, sha224);
can_login_with_configured_password_format(Host, cyrsasl_scram_sha256) ->
    is_password_format_allowed(Host, sha256);
can_login_with_configured_password_format(Host, cyrsasl_scram_sha384) ->
    is_password_format_allowed(Host, sha384);
can_login_with_configured_password_format(Host, cyrsasl_scram_sha512) ->
    is_password_format_allowed(Host, sha512).

is_password_format_allowed(Host, Sha) ->
    case ejabberd_auth:get_opt(Host, password_format) of
        undefined -> true;
        plain -> true;
        scram -> true;
        {scram, ConfiguredSha} -> lists:member(Sha, ConfiguredSha)
    end.

%% This function is exported and used from other modules
iterations() -> ?SCRAM_DEFAULT_ITERATION_COUNT.

iterations(Host) ->
    ejabberd_auth:get_opt(Host, scram_iterations, ?SCRAM_DEFAULT_ITERATION_COUNT).

password_to_scram(Host, Password) ->
    password_to_scram(Host, Password, ?SCRAM_DEFAULT_ITERATION_COUNT).

password_to_scram(_, #scram{} = Password, _) ->
    scram_record_to_map(Password);
password_to_scram(Host, Password, IterationCount) ->
    Salt = crypto:strong_rand_bytes(?SALT_LENGTH),
    ServerStoredKeys = [password_to_scram(Password, Salt, IterationCount, HashType)
                            || {HashType, _Prefix} <- configured_sha_types(Host)],
    ResultList = lists:merge([{salt, base64:encode(Salt)},
                              {iteration_count, IterationCount}], ServerStoredKeys),
    maps:from_list(ResultList).

password_to_scram(Password, Salt, IterationCount, HashType) ->
    SaltedPassword = salted_password(HashType, Password, Salt, IterationCount),
    StoredKey = stored_key(HashType, client_key(HashType, SaltedPassword)),
    ServerKey = server_key(HashType, SaltedPassword),
    {HashType, #{server_key => base64:encode(ServerKey),
                 stored_key => base64:encode(StoredKey)}}.

check_password(Password, Scram) when is_record(Scram, scram)->
    ScramMap = scram_record_to_map(Scram),
    check_password(Password, ScramMap);
check_password(Password, ScramMap) when is_map(ScramMap) ->
    #{salt := Salt, iteration_count := IterationCount} = ScramMap,
    [Sha | _] = [ShaKey || {ShaKey, _Prefix} <- supported_sha_types(),
                                                maps:is_key(ShaKey, ScramMap)],
    #{Sha := #{stored_key := StoredKey}} = ScramMap,
    SaltedPassword = salted_password(Sha, Password, base64:decode(Salt), IterationCount),
    ClientStoredKey = stored_key(Sha, client_key(Sha, SaltedPassword)),
    ClientStoredKey == base64:decode(StoredKey).

serialize(#scram{storedkey = StoredKey, serverkey = ServerKey,
                 salt = Salt, iterationcount = IterationCount})->
    IterationCountBin = integer_to_binary(IterationCount),
    << <<?SCRAM_SERIAL_PREFIX>>/binary,
       StoredKey/binary, $,, ServerKey/binary,
       $,, Salt/binary, $,, IterationCountBin/binary>>;
serialize(#{salt   := Salt, iteration_count := IterationCount} = ScramMap) ->
    IterationCountBin = integer_to_binary(IterationCount),
    ConfigedSha = [{ShaKey, Prefix} || {ShaKey, Prefix} <- supported_sha_types(),
                                                           maps:is_key(ShaKey, ScramMap)],
    Header = [?MULTI_SCRAM_SERIAL_PREFIX, Salt, $, , IterationCountBin],
    do_serialize(Header, ScramMap, ConfigedSha).

do_serialize(Serialized, _ ,[]) ->
    erlang:iolist_to_binary(Serialized);
do_serialize(Header, ScramMap, [{Sha, Prefix} | RemainingSha]) ->
    #{Sha := #{server_key := ServerKey, stored_key := StoredKey}} = ScramMap,
    ShaSerialization = [$, , Prefix, StoredKey, $|, ServerKey],
    NewHeader = [Header | ShaSerialization],
    do_serialize(NewHeader, ScramMap, RemainingSha).

deserialize(<<?SCRAM_SERIAL_PREFIX, Serialized/binary>>) ->
    case catch binary:split(Serialized, <<",">>, [global]) of
        [StoredKey, ServerKey, Salt, IterationCount] ->
            {ok, #{salt => Salt,
                   iteration_count => binary_to_integer(IterationCount),
                   sha => #{stored_key => StoredKey, server_key => ServerKey}}};
        _ ->
            ?WARNING_MSG("Incorrect serialized SCRAM: ~p", [Serialized]),
            {error, incorrect_scram}
    end;
deserialize(<<?MULTI_SCRAM_SERIAL_PREFIX, Serialized/binary>>) ->
    case catch binary:split(Serialized, <<",">>, [global]) of
        [Salt, IterationCountBin | ListOfShaSpecificDetails] ->
            IterationCount = binary_to_integer(IterationCountBin),
            DeserializedKeys = [deserialize(supported_sha_types(), ShaDetails)
                                             || ShaDetails <- ListOfShaSpecificDetails],
            ResultList = lists:merge([{salt, Salt}, {iteration_count, IterationCount}],
                                     lists:flatten(DeserializedKeys)),
            {ok, maps:from_list(ResultList)};
        _ ->
            ?WARNING_MSG("Incorrect serialized SCRAM: ~p", [Serialized]),
            {error, incorrect_scram}
    end;
deserialize(Bin) ->
    ?WARNING_MSG("Corrupted serialized SCRAM: ~p", [Bin]),
    {error, corrupted_scram}.

deserialize([], _) ->
    [];
deserialize([{Sha, Prefix} | _RemainingSha],
    <<Prefix:10/binary, StoredServerKeys/binary>>) ->
    case catch binary:split(StoredServerKeys, <<"|">>, [global]) of
        [StoredKey, ServerKey] ->
            {Sha, #{server_key => ServerKey, stored_key => StoredKey}};
        _ ->
            ?WARNING_MSG("Incorrect serialized SCRAM: ~p", [StoredServerKeys])
    end;
deserialize([_CurrentSha | RemainingSha], ShaDetails) ->
    deserialize(RemainingSha, ShaDetails).

-spec scram_to_tuple(scram()) -> scram_tuple().
scram_to_tuple(Scram) ->
    {base64:decode(Scram#scram.storedkey),
     base64:decode(Scram#scram.serverkey),
     base64:decode(Scram#scram.salt),
     Scram#scram.iterationcount}.

-spec scram_record_to_map(scram()) -> scram_map().
scram_record_to_map(Scram) ->
    #{salt => Scram#scram.salt,
      iteration_count => Scram#scram.iterationcount,
      sha => #{stored_key => Scram#scram.storedkey,
               server_key => Scram#scram.serverkey}}.

-spec check_digest(Scram, binary(), fun(), binary()) -> boolean() when
    Scram :: scram_map() | scram().
check_digest(Scram, Digest, DigestGen, Password) when is_record(Scram, scram) ->
    ScramMap = scram_record_to_map(Scram),
    check_digest(ScramMap, Digest, DigestGen, Password);
check_digest(ScramMap, Digest, DigestGen, Password) ->
    do_check_digest(supported_sha_types(), ScramMap, Digest, DigestGen, Password).

do_check_digest([] , _, _, _, _) ->
    false;
do_check_digest([{Sha,_Prefix} | RemainingSha], ScramMap, Digest, DigestGen, Password) ->
    #{Sha := #{stored_key := StoredKey}} = ScramMap,
    Passwd = base64:decode(StoredKey),
    case ejabberd_auth:check_digest(Digest, DigestGen, Password, Passwd) of
        true  -> true;
        false -> do_check_digest(RemainingSha, Digest, DigestGen, Password, Passwd)
    end.

supported_sha_types() ->
    [{sha,      <<?SCRAM_SHA_PREFIX>>},
     {sha224,   <<?SCRAM_SHA224_PREFIX>>},
     {sha256,   <<?SCRAM_SHA256_PREFIX>>},
     {sha384,   <<?SCRAM_SHA384_PREFIX>>},
     {sha512,   <<?SCRAM_SHA512_PREFIX>>}].

configured_sha_types(Host) ->
    case catch ejabberd_auth:get_opt(Host, password_format) of
        {scram, ScramSha} when length(ScramSha) > 0 ->
            lists:filter(fun({Sha, _Prefix}) ->
                            lists:member(Sha, ScramSha) end, supported_sha_types());
        _ -> supported_sha_types()
    end.
