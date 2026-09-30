defmodule ProbeTwoTest do
  @moduledoc false
  use CourierWeb.ConnCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint CourierWeb.Endpoint

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp show(label, fun) do
    conn =
      try do
        fun.(build_conn())
      rescue
        e ->
          IO.puts("PROBE2\t#{label}\tRAISED #{inspect(e.__struct__)}")

          case e do
            %{conn: c} -> c
            _ -> nil
          end
      end

    if conn do
      IO.puts(
        "PROBE2\t#{label}\t#{conn.status}\t#{inspect(Plug.Conn.get_resp_header(conn, "content-type"))}"
      )

      if conn.status >= 400 do
        case Jason.decode(conn.resp_body || "") do
          {:ok, b} ->
            IO.puts("\tcode=#{inspect(b["code"])} status=#{inspect(b["status"])} title=#{inspect(b["title"])} trace?=#{is_binary(b["trace_id"])}")

          o ->
            IO.puts("\tBODY #{inspect(o)} raw=#{inspect(conn.resp_body)}")
        end
      end
    end

    conn
  end

  defp authed(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-courier-account", @account)
  end

  test "reachable statuses" do
    show("missing-endpoint", fn c -> authed(c) |> get("/v1/webhook_endpoints/" <> Ecto.UUID.generate()) end)

    show("patch-missing", fn c ->
      authed(c) |> patch("/v1/webhook_endpoints/#{Ecto.UUID.generate()}", Jason.encode!(%{status: "disabled"}))
    end)

    show("delete-missing", fn c -> authed(c) |> delete("/v1/webhook_endpoints/" <> Ecto.UUID.generate()) end)

    show("ping-missing", fn c ->
      authed(c) |> post("/v1/webhook_endpoints/#{Ecto.UUID.generate()}/test", "{}")
    end)

    # 406: the :accepts plug in the :api pipeline refuses a non-json Accept.
    show("accept-text-html", fn c ->
      c |> put_req_header("accept", "text/html") |> get("/v1/notification_preferences/#{Ecto.UUID.generate()}")
    end)

    show("accept-missing", fn c -> c |> delete_req_header("accept") |> get("/v1/nope") end)

    # A 500: a request that raises inside a controller. Forced by sending a
    # limit that is not a number at all, which the context's cast may not cover.
    show("limit-garbage", fn c -> authed(c) |> get("/v1/webhook_endpoints?limit=abc") end)
    show("cursor-huge", fn c -> authed(c) |> get("/v1/webhook_endpoints?cursor=" <> String.duplicate("A", 4000)) end)

    IO.puts("\n=== ErrorJSON mapping (what Phoenix renders for a raised exception) ===")

    for status <- [400, 401, 403, 404, 405, 406, 409, 415, 422, 429, 500, 501, 503] do
      assigns = %{trace_id: "abc", instance: "/v1/x", status: status}
      b = CourierWeb.ErrorJSON.render("#{status}.json", assigns)

      IO.puts(
        "\t#{status} -> code=#{inspect(b["code"])} type=#{b["type"]} status_field=#{inspect(b["status"])} title=#{inspect(b["title"])}"
      )
    end

    IO.puts("\n=== Problem.for_status round trip ===")

    for status <- [400, 401, 403, 404, 405, 406, 409, 415, 422, 429, 500, 503] do
      IO.puts("\tfor_status(#{status}) = #{inspect(CourierWeb.Problem.for_status(status))}")
    end

    IO.puts("PROBE2-DONE")
  end
end
