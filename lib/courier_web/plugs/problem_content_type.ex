defmodule CourierWeb.Plugs.ProblemContentType do
  @moduledoc """
  Every non-2xx response is `application/problem+json` — core's rule, and
  `CourierWeb.Problem`'s envelope is written for it.

  Phoenix decides the content type from the *format*, so an error it renders by
  itself (a 404 for a path courier does not serve, a 500) goes out as
  `application/json` with a problem+json body, and a client that switches on the
  content type reads an error as a success. This plug fixes the type where the
  status is finally known.

  `register_before_send/2` rather than a status check in a pipeline plug: the
  status of an error is decided after the pipeline has unwound, so nothing
  upstream of the failure can know it. The callback runs on the way out of every
  response, and only touches the ones that are not 2xx.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      if conn.status >= 400,
        do: put_resp_content_type(conn, "application/problem+json"),
        else: conn
    end)
  end
end
