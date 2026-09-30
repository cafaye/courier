defmodule ProbeFiveTest do
  @moduledoc false
  use CourierWeb.ConnCase, async: false
  import Plug.Conn
  @endpoint CourierWeb.Endpoint

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"
  @uuid "6f5d4c3b-2a18-4e8f-9c07-1b2d3e4f5061"

  defp raw(method, path, body, headers) do
    Enum.reduce(headers, build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> then(fn c -> dispatch(c, method, path, body) end)
  end

  defp report(label, conn) do
    IO.puts(
      "RAW\t#{label}\t#{conn.status}\t#{inspect(Plug.Conn.get_resp_header(conn, "content-type"))}"
    )

    if conn.status >= 400 and is_binary(conn.resp_body) and conn.resp_body != "" do
      case Jason.decode(conn.resp_body) do
        {:ok, b} ->
          IO.puts(
            "\tcode=#{inspect(b["code"])} type=#{inspect(b["type"])} status=#{inspect(b["status"])} title=#{inspect(b["title"])} trace?=#{is_binary(b["trace_id"])} instance=#{inspect(b["instance"])}"
          )

        o ->
          IO.puts("\t#{inspect(o)}")
      end
    end
  end

  defp show(label, fun) do
    conn =
      try do
        fun.()
      rescue
        e ->
          case e do
            %{conn: c} -> c
            _ -> nil
          end
      end

    if conn, do: report(label, conn), else: IO.puts("RAW\t#{label}\tRAISED (no conn)")
    conn
  end

  test "400 on a GET, and 406" do
    IO.puts("\n### Is 400 reachable on a GET? (raw conn, real body) ###")

    show("GET notif + malformed body", fn ->
      raw("GET", "/v1/notification_preferences/#{@uuid}", "{not json", [
        {"content-type", "application/json"}
      ])
    end)

    show("GET webhooks(authed) + malformed body", fn ->
      raw("GET", "/v1/webhook_endpoints", "{not json", [
        {"content-type", "application/json"},
        {"x-courier-account", @account}
      ])
    end)

    show("HEAD notif + malformed body", fn ->
      raw("HEAD", "/v1/notification_preferences/#{@uuid}", "{not json", [
        {"content-type", "application/json"}
      ])
    end)

    IO.puts("\n### Is 406 reachable, and what does the client get? ###")

    show("GET notif Accept text/html", fn ->
      raw("GET", "/v1/notification_preferences/#{@uuid}", nil, [{"accept", "text/html"}])
    end)

    show("GET notif Accept application/xml", fn ->
      raw("GET", "/v1/notification_preferences/#{@uuid}", nil, [{"accept", "application/xml"}])
    end)

    show("POST webhooks(authed) Accept text/html", fn ->
      raw("POST", "/v1/webhook_endpoints", "{}", [
        {"accept", "text/html"},
        {"content-type", "application/json"},
        {"x-courier-account", @account}
      ])
    end)

    IO.puts("\n### Is 415 reachable? (pass: */*) ###")

    show("POST webhooks(authed) content-type application/xml", fn ->
      raw("POST", "/v1/webhook_endpoints", "<a/>", [
        {"content-type", "application/xml"},
        {"x-courier-account", @account}
      ])
    end)

    show("POST webhooks(authed) content-type text/plain", fn ->
      raw("POST", "/v1/webhook_endpoints", "hello", [
        {"content-type", "text/plain"},
        {"x-courier-account", @account}
      ])
    end)

    IO.puts("\n### 405? Phoenix's NoRouteError for an unrouted verb ###")

    for verb <- ~w(GET POST PUT PATCH DELETE) do
      show("#{verb} /v1/webhook_endpoints (routed verb conflict)", fn ->
        raw(verb, "/v1/webhook_endpoints", nil, [{"x-courier-account", @account}])
      end)
    end

    IO.puts("RAW-DONE")
  end
end
