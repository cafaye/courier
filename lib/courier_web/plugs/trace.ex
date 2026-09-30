defmodule CourierWeb.Plugs.Trace do
  @moduledoc """
  Gives every request an id and remembers the path it was made to.

  Two things the error envelope needs and cannot invent later:

    * **`:trace_id`** — echoed in the `X-Trace-Id` response header and in the
      problem body, and core's rule is that they match. Support starts from that
      id, so it has to be the same one on both sides of the response.
    * **`:instance`** — the path, which the problem body names. For a request
      that matched no route there is no controller and no params, so the path is
      captured here or not at all.

  This is the endpoint's first plug on purpose. `Plug.Static` can raise in dev,
  `Plug.Parsers` raises on a malformed body, and the router raises
  `NoRouteError` on a path courier does not serve — and Phoenix renders all
  three from the assigns this plug left behind. A trace id that existed only for
  requests that reached a controller would be missing from exactly the failures
  that are hardest to read.

  An id already on the conn is kept, so an upstream proxy or a caller that set
  one is not overwritten.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    trace_id = conn.assigns[:trace_id] || Ecto.UUID.generate()

    conn
    |> assign(:trace_id, trace_id)
    |> assign(:instance, conn.request_path)
    |> put_resp_header("x-trace-id", trace_id)
  end
end
