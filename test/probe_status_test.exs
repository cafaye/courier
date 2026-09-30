defmodule ProbeStatusTest do
  @moduledoc false
  # THROWAWAY PROBE. Deleted before commit. Establishes ground truth: which
  # statuses courier's endpoint can actually be made to return, by sending real
  # requests through Phoenix.ConnTest and recording status + content-type + body.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint CourierWeb.Endpoint

  # Phoenix re-raises after rendering, and a Plug.Conn is a mutable struct, so the
  # conn we pass in carries the response the client would actually have got.
  defp probe(label, fun) do
    conn =
      try do
        fun.(build_conn())
      rescue
        error ->
          IO.puts("\t(raised #{inspect(error.__struct__)}, re-raised by Phoenix)")
          # RenderErrors already sent the response onto the conn Phoenix was
          # dispatching; recover it from the exception's `%conn{}` when present.
          case error do
            %{conn: c} -> c
            _ -> build_conn()
          end
      end

    IO.puts(
      "PROBE\t#{label}\t#{conn.status}\t#{inspect(Plug.Conn.get_resp_header(conn, "content-type"))}"
    )

    if conn.status >= 400 do
      case Jason.decode(conn.resp_body || "") do
        {:ok, body} ->
          code = body["code"]
          last = body["type"] |> String.split("/") |> List.last()

          IO.puts(
            "\tcode=#{inspect(code)} type_last=#{inspect(last)} match=#{code == last} " <>
              "trace_id?=#{is_binary(body["trace_id"])} instance=#{inspect(body["instance"])} " <>
              "status=#{inspect(body["status"])} title=#{inspect(body["title"])}"
          )

        other ->
          IO.puts("\tBODY-BAD #{inspect(other)} raw=#{inspect(conn.resp_body)}")
      end
    end

    conn
  end

  defp json(conn), do: put_req_header(conn, "content-type", "application/json")

  defp authed(conn) do
    conn
    |> json()
    |> put_req_header("x-courier-account", "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061")
  end

  test "probe" do
    probe("unknown-route", &get(&1, "/v1/nope"))
    probe("wrong-method-on-real-path", &delete(&1, "/v1/webhook_endpoints"))

    probe("malformed-body", &json(&1) |> post("/v1/webhook_endpoints", "{not json"))

    probe("unsupported-media-type", fn c ->
      put_req_header(c, "content-type", "application/xml")
      |> post("/v1/webhook_endpoints", "<a/>")
    end)

    probe("not-acceptable-accept-header", fn c ->
      put_req_header(c, "accept", "text/html")
      |> get("/v1/notification_preferences/x")
    end)

    probe("unauthenticated-webhooks", &get(&1, "/v1/webhook_endpoints"))
    probe("non-uuid-user", &get(&1, "/v1/notification_preferences/not-a-uuid"))
    probe("bad-limit", &authed(&1) |> get("/v1/webhook_endpoints?limit=0"))
    probe("bad-cursor", &authed(&1) |> get("/v1/webhook_endpoints?cursor=zzzz"))

    probe("missing-endpoint", fn c ->
      authed(c) |> get("/v1/webhook_endpoints/" <> Ecto.UUID.generate())
    end)

    probe("blocked-url", fn c ->
      authed(c) |> post("/v1/webhook_endpoints", Jason.encode!(%{url: "http://127.0.0.1/x"}))
    end)

    probe("create-missing-url", fn c -> authed(c) |> post("/v1/webhook_endpoints", "{}") end)

    probe("put-collection", fn c -> json(c) |> put("/v1/webhook_endpoints", "{}") end)
    probe("options", &options(&1, "/v1/webhook_endpoints"))
    probe("head-webhooks", &head(&1, "/v1/webhook_endpoints"))
    probe("healthz", &get(&1, "/healthz"))
    probe("readyz", &get(&1, "/readyz"))

    IO.puts("\n=== 500-family envelope, rendered the way a raised exception is ===")

    for status <- [400, 401, 403, 404, 405, 406, 409, 415, 422, 429, 500, 503] do
      assigns = %{trace_id: "0af7651916cd43dd8448eb211c80319c", instance: "/v1/x", status: status}
      body = CourierWeb.ErrorJSON.render("#{status}.json", assigns)
      code = body["code"]
      last = body["type"] |> String.split("/") |> List.last()

      IO.puts(
        "\t#{status} -> code=#{inspect(code)} type=#{body["type"]} " <>
          "slug_matches=#{code == last} title=#{inspect(body["title"])}"
      )
    end

    IO.puts("PROBE-DONE")
  end
end
