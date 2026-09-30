defmodule Courier.SecretBox do
  @moduledoc """
  Sealing: a webhook signing secret at rest, as AES-256-GCM.

  A signing secret is a credential. Anyone who reads it out of the database can
  mint a delivery that courier's name is on and that verifies against every
  consumer running the official Standard Webhooks library. A hash does not solve
  this — courier has to *sign with* the secret on every delivery, so it needs the
  bytes back, which rules out one-way functions and makes "just hash it" the
  wrong instinct rather than the cautious one.

  Why AES-GCM and not a bare `:crypto.encrypt/4`: GCM is authenticated, so a
  tampered ciphertext fails to open instead of decrypting to garbage that gets
  signed. `seal/2` takes the nonce from `:crypto.strong_rand_bytes/1` on every
  call, which is why sealing the same secret twice gives different bytes — that
  is a test, not an accident.

  The key comes from configuration (32 bytes, base64), never from the database.
  A key stored beside the ciphertext it protects is a key that protects nothing.
  In production it is read from the environment at boot; see `config/runtime.exs`.
  """

  @aad "courier:webhook-secret:v1"

  @doc """
  Encrypts `plaintext` under the configured key.

  Returns the base64 of `nonce || ciphertext || tag`.
  """
  @spec seal(binary(), binary()) :: String.t()
  def seal(plaintext, key \\ key()) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @aad, true)

    Base.encode64(nonce <> tag <> ciphertext)
  end

  @doc """
  Decrypts what `seal/2` produced.

  `{:error, :invalid_ciphertext}` for anything else — a value that was never
  sealed, a truncated one, and one sealed under a different key all land here.
  Callers get a refusal rather than bytes they would sign with.
  """
  @spec open(String.t(), binary()) :: {:ok, binary()} | {:error, :invalid_ciphertext}
  def open(sealed, key \\ key()) when is_binary(sealed) do
    case Base.decode64(sealed) do
      {:ok, <<nonce::binary-12, tag::binary-16, ciphertext::binary>>} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
          :error -> {:error, :invalid_ciphertext}
        end

      _not_sealed ->
        {:error, :invalid_ciphertext}
    end
  end

  @doc """
  A random secret, in the form a signing key should be.
  """
  @spec generate() :: binary()
  def generate, do: :crypto.strong_rand_bytes(32)

  @doc """
  The configured key.

  Read at runtime rather than compiled in, so a key rotation is a restart with a
  new environment and not a rebuild. A key that is not 32 bytes raises at the
  first call rather than silently truncating: a key that is the wrong length is a
  configuration error, and every message signed with the wrong key fails
  verification at the customer, which is the most expensive possible way to learn.
  """
  @spec key() :: binary()
  def key do
    case Application.get_env(:courier, :secret_box_key) do
      nil ->
        raise ArgumentError, """
        no sealing key configured.

        Set COURIER_SECRET_BOX_KEY to 32 bytes, base64-encoded. Without it a
        webhook signing secret cannot be stored safely, and the alternative —
        storing it in the clear — is not one.
        """

      encoded when is_binary(encoded) ->
        case Base.decode64(encoded) do
          {:ok, key} when byte_size(key) == 32 ->
            key

          _other ->
            raise ArgumentError, "COURIER_SECRET_BOX_KEY must decode to exactly 32 bytes"
        end
    end
  end
end
