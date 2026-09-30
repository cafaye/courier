defmodule ProbeFourTest do
  @moduledoc false
  use CourierWeb.ConnCase, async: false
  import Plug.Conn
  @endpoint CourierWeb.Endpoint

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @uuid "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp authed(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-courier-account", @account)
  end

  # Ask: for THIS operation, given a request that a client can actually make, is
  # the status reachable? A status reachable only on some other path is not
  # reachable here.
  defp reach(label, fun) do
    conn =
      try do
        fun.(build_conn())
      rescue
        e ->
          case e do
            %{conn: c} -> c
            _ -> nil
          end
      end

    if conn do
      IO.puts("REACH\t#{label}\t#{conn.status}\t#{conn.state}")
    else
      IO.puts("REACH\t#{label}\tRAISED")
    end
  end

  test "per-operation reachability" do
    np = "/v1/notification_preferences/#{@uuid}"

    IO.puts("\n--- GET /v1/notification_preferences/{user_id} ---")
    reach("200", &get(&1, np))
    reach("406", fn c -> put_req_header(c, "accept", "text/html") |> get(np) end)
    reach("422", &get(&1, "/v1/notification_preferences/not-a-uuid"))
    reach("401", &get(&1, "/v1/notification_preferences/#{Ecto.UUID.generate()}"))
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> get(np, "{bad") end)

    IO.puts("\n--- PUT /v1/notification_preferences/{user_id} ---")
    reach("200", fn c -> put_req_header(c, "content-type", "application/json") |> put(np, ~s({"preferences":[]})) end)
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> put(np, "{bad") end)
    reach("422", fn c -> put_req_header(c, "content-type", "application/json") |> put(np, "{}") end)
    reach("406", fn c -> put_req_header(c, "accept", "text/html") |> put(np, "{}") end)
    reach("401", fn c -> put_req_header(c, "content-type", "application/json") |> put(np, "{}") end)

    IO.puts("\n--- GET /v1/webhook_endpoints ---")
    reach("200", fn c -> authed(c) |> get("/v1/webhook_endpoints") end)
    reach("401", &get(&1, "/v1/webhook_endpoints"))
    reach("422", fn c -> authed(c) |> get("/v1/webhook_endpoints?limit=0") end)
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> get("/v1/webhook_endpoints", "{bad") end)
    reach("406", fn c -> authed(c) |> put_req_header("accept", "text/html") |> get("/v1/webhook_endpoints") end)

    IO.puts("\n--- POST /v1/webhook_endpoints ---")
    reach("201", fn c -> authed(c) |> post("/v1/webhook_endpoints", ~s({"url":"https://hooks.example.com/a"})) end)
    reach("401", fn c -> put_req_header(c, "content-type", "application/json") |> post("/v1/webhook_endpoints", "{}") end)
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> post("/v1/webhook_endpoints", "{bad") end)
    reach("422", fn c -> authed(c) |> post("/v1/webhook_endpoints", "{}") end)
    reach("409", fn c -> authed(c) |> put_req_header("idempotency-key", "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061") |> post("/v1/webhook_endpoints", ~s({"url":"https://hooks.example.com/a"})) end)
    reach("406", fn c -> authed(c) |> put_req_header("accept", "text/html") |> post("/v1/webhook_endpoints", "{}") end)
    reach("429", fn c -> authed(c) |> post("/v1/webhook_endpoints", "{}") end)

    IO.puts("\n--- GET /v1/webhook_endpoints/{id} ---")
    reach("200", fn c -> authed(c) |> get("/v1/webhook_endpoints/#{@uuid}") end)
    reach("401", &get(&1, "/v1/webhook_endpoints/#{@uuid}"))
    reach("404", fn c -> authed(c) |> get("/v1/webhook_endpoints/#{Ecto.UUID.generate()}") end)
    reach("406", fn c -> authed(c) |> put_req_header("accept", "text/html") |> get("/v1/webhook_endpoints/#{@uuid}") end)

    IO.puts("\n--- PATCH /v1/webhook_endpoints/{id} ---")
    reach("200", fn c -> authed(c) |> patch("/v1/webhook_endpoints/#{@uuid}", ~s({"description":"x"})) end)
    reach("401", fn c -> put_req_header(c, "content-type", "application/json") |> patch("/v1/webhook_endpoints/#{@uuid}", "{}") end)
    reach("404", fn c -> authed(c) |> patch("/v1/webhook_endpoints/#{Ecto.UUID.generate()}", "{}") end)
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> patch("/v1/webhook_endpoints/#{@uuid}", "{bad") end)
    reach("422", fn c -> authed(c) |> patch("/v1/webhook_endpoints/#{Ecto.UUID.generate()}", "{}") end)

    IO.puts("\n--- DELETE /v1/webhook_endpoints/{id} ---")
    reach("204", fn c -> authed(c) |> delete("/v1/webhook_endpoints/#{@uuid}") end)
    reach("401", &delete(&1, "/v1/webhook_endpoints/#{@uuid}"))
    reach("404", fn c -> authed(c) |> delete("/v1/webhook_endpoints/#{Ecto.UUID.generate()}") end)

    IO.puts("\n--- POST /v1/webhook_endpoints/{id}/test ---")
    reach("200", fn c -> authed(c) |> post("/v1/webhook_endpoints/#{@uuid}/test", "{}") end)
    reach("401", fn c -> put_req_header(c, "content-type", "application/json") |> post("/v1/webhook_endpoints/#{@uuid}/test", "{}") end)
    reach("404", fn c -> authed(c) |> post("/v1/webhook_endpoints/#{Ecto.UUID.generate()}/test", "{}") end)
    reach("400", fn c -> put_req_header(c, "content-type", "application/json") |> post("/v1/webhook_endpoints/#{@uuid}/test", "{bad") end)
    reach("409", fn c -> authed(c) |> post("/v1/webhook_endpoints/#{@uuid}/test", "{}") end)

    IO.puts("REACH-DONE")
  end
end
