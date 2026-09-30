defmodule ProbeThreeTest do
  @moduledoc false
  use CourierWeb.ConnCase, async: false
  import Plug.Conn
  @endpoint CourierWeb.Endpoint

  @account "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # RenderErrors is what turns a raised exception into a response in a deployed
  # courier. Rendering it here is the same code path a 500 takes, so this is what
  # the client would receive.
  defp render_error(label, status) do
    assigns = %{
      status: status,
      trace_id: "0af7651916cd43dd8448eb211c80319c",
      instance: "/v1/webhook_endpoints",
      reason: nil
    }

    body = CourierWeb.ErrorJSON.render("#{status}.json", assigns)

    IO.puts(
      "PROBE3\t#{label}\t#{status}\tcode=#{inspect(body["code"])}\ttype=#{body["type"]}\t" <>
        "slug_ok=#{body["code"] == String.split(body["type"], "/") |> List.last()}\t" <>
        "trace?=#{is_binary(body["trace_id"])}\ttitle=#{inspect(body["title"])}"
    )
  end

  test "rendered 500-family" do
    for status <- [404, 406, 500] do
      render_error("rendered", status)
    end

    IO.puts("\n=== does GET accept a body it cannot parse? (would 400 be reachable?) ===")

    get_with_body =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> get("/v1/notification_preferences/#{Ecto.UUID.generate()}", "{not json")

    IO.puts("PROBE3\tGET-with-malformed-body\t#{get_with_body.status}")

    put_with_body =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put("/v1/notification_preferences/#{Ecto.UUID.generate()}", "{not json")

    IO.puts("PROBE3\tPUT-with-malformed-body\t#{put_with_body.status}")

    IO.puts("\n=== is 415 reachable given pass: [\"*/*\"]? ===")

    xml =
      build_conn()
      |> put_req_header("content-type", "application/xml")
      |> put_req_header("x-courier-account", @account)
      |> post("/v1/webhook_endpoints", "<a/>")

    IO.puts("PROBE3\tPOST-xml-body\t#{xml.status}")

    IO.puts("\n=== what statuses do the controllers name? ===")

    for path <- Path.wildcard("lib/courier_web/**/*.ex") do
      source = File.read!(path)

      statuses =
        Regex.scan(~r/Problem\.send\(\s*conn,\s*(\d{3})/s, source)
        |> Enum.map(fn [_, s] -> s end)
        |> Enum.uniq()
        |> Enum.sort()

      if statuses != [] or String.contains?(source, "put_status") do
        IO.puts("PROBE3\t#{path}\tProblem.send=#{inspect(statuses)}")
      end
    end

    IO.puts("PROBE3-DONE")
  end
end
