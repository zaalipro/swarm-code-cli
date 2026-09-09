defmodule SwarmCode.Domain.Search.Body do
  @moduledoc """
  The bounded response collector every HTTP reader shares (spec 51 §7.4, M7).

  `Req.get/2` with no `:into` buffers whatever the server sends: ten research
  workers each pulling a 300 MB asset is a multi-gigabyte spike inside the op
  tasks, and a `Content-Type` nobody can read is paid for in full before it is
  thrown away. The collector answers three questions on the *headers*, before
  the first chunk is kept:

    * is the media type text at all (`text/…`, JSON, XML, XHTML)? — otherwise
      halt with `{:skip, :type}`;
    * does `content-length` already exceed the cap? — halt with `{:skip, :length}`;
    * has the accumulated body reached the cap? — halt on exactly `@max_body`
      bytes, which the caller uses as it stands (the reader's own `max_chars`
      cut adds the "…[truncated]" the model sees).

  The bytes live in the response's `:private` map, not in `body`: `body` is what
  Req would decode, and a streamed response is never decoded.
  """

  @max_body 4_000_000

  # Prefix match on the media type, or suffix match for the structured-syntax
  # suffixes (`application/ld+json`, `image/svg+xml`).
  @text_types ~w(text/ application/json application/xml application/xhtml +json +xml)

  @doc "The cap, in bytes."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "The `into:` function to hand to `Req.get/2` or `Req.post/2`."
  @spec collector() :: (term(), term() -> {:cont | :halt, term()})
  def collector do
    fn {:data, chunk}, {req, resp} ->
      cond do
        not text_type?(resp) ->
          {:halt, {req, Req.Response.put_private(resp, :skip, :type)}}

        too_long?(resp) ->
          {:halt, {req, Req.Response.put_private(resp, :skip, :length)}}

        true ->
          body = (resp.private[:body] || "") <> chunk

          if byte_size(body) > @max_body,
            do:
              {:halt,
               {req, Req.Response.put_private(resp, :body, binary_part(body, 0, @max_body))}},
            else: {:cont, {req, Req.Response.put_private(resp, :body, body)}}
      end
    end
  end

  @doc """
  What the collector kept: `{:ok, body}`, or `{:skip, :type | :length, content_type}`
  when it refused the response.
  """
  @spec read(Req.Response.t()) :: {:ok, binary()} | {:skip, :type | :length, String.t()}
  def read(resp) do
    case resp.private[:skip] do
      nil -> {:ok, resp.private[:body] || ""}
      reason -> {:skip, reason, content_type(resp)}
    end
  end

  @doc "The response's `content-type`, or `\"\"`."
  @spec content_type(Req.Response.t()) :: String.t()
  def content_type(resp),
    do: resp |> Req.Response.get_header("content-type") |> List.first() || ""

  # A server that names no type is given the benefit of the doubt — plenty of
  # plain-text endpoints send none, and `String.replace_invalid/1` downstream
  # copes with whatever arrives.
  defp text_type?(resp) do
    media =
      resp
      |> content_type()
      |> String.downcase()
      |> String.split(";")
      |> List.first()
      |> to_string()
      |> String.trim()

    media == "" or
      Enum.any?(@text_types, fn type ->
        if String.starts_with?(type, "+"),
          do: String.ends_with?(media, type),
          else: String.starts_with?(media, type)
      end)
  end

  defp too_long?(resp) do
    case resp |> Req.Response.get_header("content-length") |> List.first() do
      nil -> false
      value -> match?({length, _rest} when length > @max_body, Integer.parse(value))
    end
  end
end
