defmodule CourierWeb.OpenAPIDocumentTest do
  @moduledoc """
  `openapi.yaml` and `lib/courier_web/router.ex` have to describe the same
  service, and this is the test that holds them to it.

  PLAN.md MD6 has the platform generating client SDKs from these documents, so a
  path in `openapi.yaml` is a method on a generated client and a route in the
  router that the document does not mention is a method it does not have. Both
  directions are failures here, and both were real: `/v1/notification_preferences`
  was in the router with tests behind it and absent from the document, which is
  the omission courier-03 flagged and this closes.

  ## How it can fail, and how it cannot

  It reads both sides (`Courier.TestSupport.OpenAPIPaths`) and compares the
  **paths**, never a count. A count comparison is the shape that misses the
  change that matters: a rename leaves the count alone and a pure addition
  breaks it, which is exactly backwards.

  It cannot pass by reading nothing. Every way the readers could under-read is a
  raised error rather than an empty set, and the two guards below assert that
  each side produced operations at all — because two empty sets agree.

  ## The one omission that stays an omission

  `/healthz` and `/readyz` are not in the document and are not going to be. They
  run before auth, routing and the rest of the platform exist, no customer codes
  against them, and the document's header says so. They are named in
  `excluded/0` with the reason, and the check prints them every time it fails,
  so a carve-out reads as a decision rather than as a gap. The exclusion is
  keyed by method *and* path, so it covers `GET /healthz` and not
  `DELETE /healthz`, and a test asserts every exclusion still names a route the
  router serves — a rename cannot hide behind an exclusion that has gone stale.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.OpenAPIPaths, as: Paths

  @document "openapi.yaml"

  # courier's declared omissions, one operation each, with the reason. Keyed by
  # `{method, path}` in normalised form, because a carve-out that named a path
  # rather than an operation would cover every method on it.
  @excluded [
    {"GET", "/healthz",
     "an infrastructure probe: it runs before auth, routing and the rest of the platform " <>
       "exist, no customer codes against it, and `openapi.yaml`'s header says so"},
    {"GET", "/readyz",
     "an infrastructure probe, same as `/healthz`, and it reports on courier's own " <>
       "database rather than on anything a caller asked for"}
  ]

  setup_all do
    document = Paths.document_operations!(@document)
    router = Paths.router_operations!()

    exclusions =
      Map.new(@excluded, fn {method, path, reason} ->
        {Paths.normalise_operation(method, path), reason}
      end)

    diff = Paths.diff(document, router, exclusions)

    %{
      document: document,
      router: router,
      exclusions: exclusions,
      diff: diff,
      message: Paths.describe_drift(diff)
    }
  end

  test "the document was read, and it is not empty", %{document: document} do
    # Without this the test below would compare an empty set against an empty set
    # and go green having checked nothing. The reader raises on most ways of
    # under-reading; this catches the rest.
    assert map_size(document) > 0,
           "#{@document} was read as documenting no operations at all. A check over " <>
             "none passes, and a green check over nothing is worse than no check — " <>
             "the reader would have stopped understanding the file."
  end

  test "the router was read, and it is not empty", %{router: router} do
    assert map_size(router) > 0,
           "CourierWeb.Router was read as serving no routes at all. A router-reading " <>
             "check that finds nothing agrees with a document that finds nothing."
  end

  test "every operation the document describes is a route the router serves", %{diff: diff} do
    # The dangerous direction, and the one that 404s a customer: an endpoint in
    # the menu that answers 404 is a product configured against a route that does
    # not exist, and they find out at their outage.
    assert diff.documented_not_served == [],
           """
           openapi.yaml documents a route the router does not serve.

           #{Paths.describe_drift(diff)}
           """
  end

  test "every route the router serves is an operation the document describes", %{diff: diff} do
    # The other direction. This was the real drift courier-03 reported, and it is
    # a failure rather than a warning because the gap has been closed: there is
    # nothing left to warn about, and a warning that is never acted on is a note
    # in a file nobody reads. What remains deliberately out of the document is in
    # `excluded/0`, with a reason, and is printed on every failure.
    assert diff.unexplained == [],
           """
           the router serves a route openapi.yaml does not describe.

           #{Paths.describe_drift(diff)}
           """
  end

  test "a declared omission still names a route the router serves", %{
    router: router,
    exclusions: exclusions
  } do
    # The stale-exclusion guard. If `/healthz` were renamed, or removed, the
    # exclusion above would still be in the list while no longer matching anything
    # — and a carve-out that matches nothing is a hole waiting for the next route
    # to fall into it.
    for {{method, path}, _reason} <- Map.keys(exclusions) do
      assert Map.has_key?(router, {method, path}),
             "the exclusion for #{method} #{path} names a route the router does not " <>
               "serve. Either the route was renamed or removed, in which case the " <>
               "exclusion has to go with it, or the exclusion is hiding a route that " <>
               "belongs in the document."
    end
  end

  test "the document's header names every route it deliberately leaves out", %{
    exclusions: exclusions
  } do
    # The header is the only thing a reader of the document has to go on: a
    # document that silently omits a route is worse than one that says what it
    # covers. So an omission the check tolerates has to be an omission the
    # document admits, in words, in its first paragraph.
    header = @document |> File.read!() |> String.split("openapi: 3.1.0") |> List.first()

    for {{_method, path}, _reason} <- Map.keys(exclusions) do
      assert header =~ path,
             "#{@document} leaves #{path} out, and its header does not say so. The " <>
               "check tolerates the omission because courier's own header declares it; " <>
               "a header that has stopped saying it makes the omission silent again, " <>
               "which is the thing courier-03 was right to flag."
    end
  end

  test "the exclusions are the probes and nothing else" do
    # Not a route list — a bound. A carve-out set that grows is a document losing
    # its coverage quietly, and the number is here so that growth is a change
    # somebody reads rather than a diff line that scrolls past.
    assert Map.keys(normalised_exclusions()) |> Enum.sort() == [
             {"GET", "/healthz"},
             {"GET", "/readyz"}
           ]
  end

  defp normalised_exclusions do
    Map.new(@excluded, fn {method, path, reason} ->
      {Paths.normalise_operation(method, path), reason}
    end)
  end
end
