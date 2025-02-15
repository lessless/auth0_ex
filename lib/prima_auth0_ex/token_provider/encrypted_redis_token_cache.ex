defmodule PrimaAuth0Ex.TokenProvider.EncryptedRedisTokenCache do
  @moduledoc """
  Implementation of `PrimaAuth0Ex.TokenProvider.TokenCache` that persists encrypted copies of tokens on Redis.

  Encryption-related functionalities are implemented in `PrimaAuth0Ex.TokenProvider.TokenEncryptor`.
  """

  require Logger
  alias PrimaAuth0Ex.Config
  alias PrimaAuth0Ex.TokenProvider.{TokenCache, TokenEncryptor, TokenInfo}

  @behaviour TokenCache

  @impl TokenCache
  def get_token_for(client \\ :default_client, audience) do
    if cache_enabled?(), do: do_get_token_for(client, audience), else: {:ok, nil}
  end

  @impl TokenCache
  def set_token_for(client \\ :default_client, audience, token) do
    if cache_enabled?(), do: do_set_token_for(client, audience, token), else: :ok
  end

  defp do_get_token_for(client, audience) do
    key = key_for(client, audience)

    case Redix.command(PrimaAuth0Ex.Redix, ["GET", key]) do
      {:ok, nil} ->
        Logger.info("Token not found on redis.", audience: audience, key: key)
        {:ok, nil}

      {:ok, cached_value} ->
        decrypt_and_parse(cached_value)

      {:error, reason} ->
        Logger.warn("Error retrieving token from redis.",
          audience: audience,
          key: key,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp do_set_token_for(client, audience, token) do
    with {:ok, json_token} <- to_json(token),
         {:ok, encrypted} <- TokenEncryptor.encrypt(json_token),
         {:ok, _} <- save(encrypted, key_for(client, audience), token.expires_at) do
      Logger.info("Updated token on redis.", audience: audience)
      :ok
    else
      {:error, reason} ->
        Logger.error("Error setting token on redis.", audience: audience, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp key_for(client, audience), do: "prima_auth0_ex_tokens:#{namespace(client)}:#{audience}"

  defp save(token, key, expires_at) do
    expires_in = expires_at - current_time()

    Redix.command(PrimaAuth0Ex.Redix, ["SET", key, token, "EX", expires_in])
  end

  defp decrypt_and_parse(cached_value) do
    with {:ok, decrypted} <- TokenEncryptor.decrypt(cached_value),
         {:ok, token_attributes} <- Jason.decode(decrypted) do
      build_token(token_attributes)
    else
      {:error, message} ->
        Logger.warn("Found invalid data on redis.", message: inspect(message))
        {:error, message}
    end
  end

  defp to_json(token), do: Jason.encode(token)

  defp build_token(%{"jwt" => jwt, "issued_at" => issued_at, "expires_at" => expires_at} = token) do
    {:ok, %TokenInfo{jwt: jwt, issued_at: issued_at, expires_at: expires_at, kid: token["kid"]}}
  end

  defp build_token(_), do: {:error, :malformed_cached_data}

  defp cache_enabled?,
    do: Config.redis(:enabled, true)

  defp namespace(:default_client),
    do: Config.default_client!(:cache_namespace)

  defp namespace(client),
    do: Config.clients!(client, :cache_namespace)

  defp current_time, do: Timex.to_unix(Timex.now())
end
