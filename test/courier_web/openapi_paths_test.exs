defmodule CourierWeb.OpenAPIPathsTest do
  @moduledoc """
  The reader's own tests, and the tests for every normalisation it applies.

  This file exists because the check in `CourierWeb.OpenAPIDocumentTest` is only
  worth having if the thing producing the two sets is itself trustworthy. A
  normaliser is a place a check can be made to pass by a rename that should have
  failed it, so every rule gets a test naming the case it covers — and the
  comparison gets tests that inject faults, because a checker that cannot be
  shown to fail has not been shown to work.

  The fault tests drive the real readers rather than hand-built maps, so the
  thing under test is the code the check runs, not a tidier imitation of it.
  """

  use ExUnit.Case, async: true

  alias Courier.TestSupport.OpenAPIPaths, as: Paths

  # A document written to the shape this repository's `openapi.yaml` uses: keys at
  # column 0, path items two in, operations four in, and bodies deeper still.
  defp write_document(lines) do
    path = Path.join(System.tmp_dir!(), "openapi-#{System.unique_integer([:positive])}.yaml")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "reading paths out of a document" do
    test "it reads a path and the methods under it, and nothing else" do
      document =
        write_document([
          "openapi: 3.1.0",
          "info:",
          "  title: courier",
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      summary: list widgets",
          "    post:",
          "    patch:",
          "    delete:",
          "  /v1/widgets/{id}:",
          "    parameters:",
          "      - $ref: '#/components/parameters/WidgetId'",
          "    get:",
          "    put:",
          "components:",
          "  schemas:",
          "    Widget:",
          "      type: object",
          "  /not_a_path:",
          "    nope: 1"
        ])

      operations = Paths.document_operations!(document)

      assert Map.keys(operations) |> Enum.sort() == [
               {"DELETE", "/v1/widgets"},
               {"GET", "/v1/widgets"},
               {"GET", "/v1/widgets/{}"},
               {"PATCH", "/v1/widgets"},
               {"POST", "/v1/widgets"},
               {"PUT", "/v1/widgets/{}"}
             ]
    end

    test "the spellings it keeps are the document's own, not the normalised key's" do
      # The failure message names the path, so it has to name the path as the
      # reader saw it: `{id}` from the document, `:id` from the router.
      document = write_document(["paths:", "  /v1/widgets/{id}:", "    get:"])
      operations = Paths.document_operations!(document)

      assert Map.fetch!(operations, {"GET", "/v1/widgets/{}"})["label"] ==
               "GET /v1/widgets/{id}"
    end

    test "a body key that merely starts with a method name is not an operation" do
      # `get:` is an operation. `getaway:` is not, and a reader that matched on
      # the prefix would count a schema property as a route.
      document =
        write_document(["paths:", "  /v1/widgets:", "    get:", "    getaway:", "    posting:"])

      assert map_size(Paths.document_operations!(document)) == 1
    end

    test "comments and blank lines inside the block are skipped" do
      document =
        write_document([
          "paths:",
          "  # the only surface courier ships with a contract",
          "  /v1/widgets:",
          "",
          "    # listing",
          "    get:",
          ""
        ])

      assert map_size(Paths.document_operations!(document)) == 1
    end

    test "the two indentation levels are derived from the document, not assumed" do
      # Four-space YAML is legal and common. A reader that hardcoded two and four
      # would read this document as having no operations at all — and a check
      # that finds nothing passes.
      document = write_document(["paths:", "    /v1/widgets:", "        get:", "        post:"])

      assert map_size(Paths.document_operations!(document)) == 2
    end

    test "anything deeper than the operation level is an operation's body, not structure" do
      # A real document nests: `parameters` holds a list of `- $ref:` entries, and
      # an operation holds a `responses:` mapping. A reader that treated every
      # deeper level as structure would count a response's status codes as routes.
      document =
        write_document([
          "paths:",
          "  /v1/widgets/{id}:",
          "    parameters:",
          "      - $ref: '#/components/parameters/WidgetId'",
          "        description:",
          "          deeper still, inside the list entry",
          "    get:",
          "      responses:",
          "        '200':",
          "          description: ok",
          "          content:",
          "            application/json:",
          "              schema:",
          "                type: object"
        ])

      assert Map.keys(Paths.document_operations!(document)) == [{"GET", "/v1/widgets/{}"}]
    end

    test "a key inside an operation's body that is spelled like a method is not an operation" do
      # The failure this guards against is specific: a schema property named
      # `delete`, three levels down inside a response body, read as a `DELETE`
      # route. It would be a phantom operation in the document, and the check
      # would demand a route that should not exist.
      document =
        write_document([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "      responses:",
          "        '200':",
          "          content:",
          "            application/json:",
          "              schema:",
          "                properties:",
          "                  delete:",
          "                    type: boolean",
          "                  patch:",
          "                    type: boolean",
          "    post:",
          "      requestBody:",
          "        content:",
          "          application/json:",
          "            schema:",
          "              properties:",
          "                get:",
          "                  type: string"
        ])

      assert Map.keys(Paths.document_operations!(document)) |> Enum.sort() ==
               [{"GET", "/v1/widgets"}, {"POST", "/v1/widgets"}]
    end

    test "a path item's own fields are not operations" do
      # OpenAPI 3.1 puts `summary`, `description` and `servers` directly under a
      # path key. They are part of the Path Item Object, not of its operations.
      document = write_document(["paths:", "  /v1/widgets:", "    summary: widgets", "    get:"])

      assert map_size(Paths.document_operations!(document)) == 1
    end
  end

  describe "the document reader refuses rather than under-reads" do
    # Every one of these is a document that would make the check pass for the
    # wrong reason, so the reader raises instead. "Finds no paths and passes" is
    # the failure mode this whole file is about.

    test "a document with no top-level paths: is an error, not an empty check" do
      document = write_document(["openapi: 3.1.0", "info:", "  title: courier"])

      assert_raise RuntimeError, ~r/no top-level `paths:`/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a paths: block with no operations under it is an error" do
      document = write_document(["paths:"])

      assert_raise RuntimeError, ~r/documents no operations/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a path item with no operation under it is an error" do
      # OpenAPI does not allow a path item with no operations, and a reader that
      # skipped it would report the router as serving something the document does
      # not describe, for the wrong reason.
      document =
        write_document(["paths:", "  /v1/widgets:", "    parameters:", "      - $ref: x"])

      assert_raise RuntimeError, ~r/no operation under/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a path key that does not start with a slash is an error, not normalised" do
      # Prepending a slash would quietly accept an invalid document and hide the
      # invalidity, so the reader refuses the document instead.
      document = write_document(["paths:", "  v1/widgets:", "    get:"])

      assert_raise RuntimeError, ~r/not a valid OpenAPI path/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a direct child of paths: that is neither a path nor a path-item field is an error" do
      document = write_document(["paths:", "  widget:", "    get:"])

      assert_raise RuntimeError, ~r/not a valid OpenAPI path/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a paths: block with one indentation level and no operations is an error" do
      document = write_document(["paths:", "  /v1/widgets:"])

      assert_raise RuntimeError, ~r/documents no operations/, fn ->
        Paths.document_operations!(document)
      end
    end

    test "a missing document is an error" do
      assert_raise RuntimeError, ~r/could not read/, fn ->
        Paths.document_operations!("/nonexistent/openapi.yaml")
      end
    end
  end

  describe "reading paths out of the router" do
    test "it reads the router's own route definitions, not a list written by hand" do
      # This is the pantry-03 lesson in one assertion: the route set has to come
      # from `__routes__/0`, or the check can only ever fail for a route somebody
      # remembered to write down.
      operations = Paths.router_operations!()

      assert Enum.any?(operations, fn {_key, op} ->
               op["path"] == "/v1/webhook_endpoints/:id" and op["method"] == "GET" and
                 op["plug"] == CourierWeb.WebhookEndpointsController and op["action"] == :show
             end)

      assert Enum.any?(operations, fn {_key, op} ->
               op["path"] == "/healthz" and op["method"] == "GET" and
                 op["plug"] == CourierWeb.HealthController
             end)
    end

    test "it records the plug and action, so a failure can say what the router does serve" do
      operations = Paths.router_operations!()

      assert Map.fetch!(operations, {"GET", "/v1/notification_preferences/{}"}) == %{
               "method" => "GET",
               "path" => "/v1/notification_preferences/:user_id",
               "label" => "GET /v1/notification_preferences/:user_id",
               "plug" => CourierWeb.NotificationPreferencesController,
               "action" => :show
             }
    end

    test "a router that defines no routes is an error, not an empty check" do
      defmodule EmptyRouter do
        def __routes__, do: []
      end

      assert_raise RuntimeError, ~r/0 routes/, fn -> Paths.router_operations!(EmptyRouter) end
    end

    test "a module that is not a router at all is an error" do
      assert_raise RuntimeError, ~r/not a Phoenix router/, fn ->
        Paths.router_operations!(Enum)
      end
    end
  end

  describe "normalising the method" do
    test "an atom verb and a string verb are the same operation" do
      # `Phoenix.Router.Route.verb` is an atom (`:get`); a document's key is the
      # string `"get"`. Neither is a difference between the two sides.
      assert Paths.normalise_method(:get) == "GET"
      assert Paths.normalise_method("get") == "GET"
      assert Paths.normalise_method("GET") == "GET"

      assert Paths.normalise_operation(:get, "/v1/widgets/{id}") ==
               Paths.normalise_operation("get", "/v1/widgets/:id")
    end

    test "a document that writes GET: and get: is a collision, not a duplicate to keep" do
      # Case folding is only safe while it cannot hide two operations. If it can,
      # the reader says so rather than quietly keeping one of them.
      document = write_document(["paths:", "  /v1/widgets:", "    get:", "    GET:"])

      assert_raise RuntimeError, ~r/both read as GET \/v1\/widgets/, fn ->
        Paths.document_operations!(document)
      end
    end
  end

  describe "normalising a path parameter" do
    test "{id} in a document and :id in the router are the same operation" do
      assert Paths.normalise_operation("GET", "/v1/webhook_endpoints/{id}") ==
               Paths.normalise_operation("GET", "/v1/webhook_endpoints/:id")
    end

    test "renaming a path parameter is not drift" do
      # A generated client substitutes a path parameter positionally, so `{id}`
      # becoming `{endpoint_id}` is a rename inside one route, not two routes.
      # Failing on it would make the check fail on a change that breaks nothing,
      # and a check that cries wolf is a check people turn off.
      assert Paths.normalise_operation("GET", "/v1/webhook_endpoints/{id}") ==
               Paths.normalise_operation("GET", "/v1/webhook_endpoints/:endpoint_id")
    end

    test "the parameter name is the only thing erased, and only inside a segment" do
      # A mechanical rewrite: the whole segment becomes `{}` whether it is
      # written `:id`, `{id}` or `{some_long_name}`. What is *not* erased is
      # which segment it was, so a path that gains or loses a parameter is still
      # a difference.
      assert Paths.normalise_path("/v1/widgets/:id") == "/v1/widgets/{}"
      assert Paths.normalise_path("/v1/widgets/:id/parts/:part_id") == "/v1/widgets/{}/parts/{}"
      assert Paths.normalise_path("/v1/widgets/extra") == "/v1/widgets/extra"
      assert Paths.normalise_path("/v1/widgets") == "/v1/widgets"
    end

    test "a path parameter is replaced by a whole segment, never by part of one" do
      # `{id}.json` is a file suffix on the same parameter. Erasing only `{id}`
      # would leave `.json` behind and produce a path the router could never serve.
      assert Paths.normalise_path("/v1/widgets/{id}.json") == "/v1/widgets/{}"
      assert Paths.normalise_path("/v1/widgets/:id.json") == "/v1/widgets/{}"
    end
  end

  describe "normalising a trailing slash" do
    test "a trailing slash is not a difference, and the router is the reason why" do
      # This is the one normalisation that could be a convenience, so it is
      # grounded in the router's own behaviour rather than in taste: Phoenix
      # resolves `/healthz/` to the `/healthz` route, so the two are the same
      # route and the check must not see them as two.
      assert %{route: "/healthz"} =
               Phoenix.Router.route_info(CourierWeb.Router, "GET", "/healthz/", "")

      assert Paths.normalise_path("/v1/webhook_endpoints/") == "/v1/webhook_endpoints"
      assert Paths.normalise_path("/v1/webhook_endpoints//") == "/v1/webhook_endpoints"
    end

    test "the root path keeps its slash" do
      assert Paths.normalise_path("/") == "/"
    end
  end

  describe "a normaliser that maps two different things onto one" do
    test "two router paths that erase to the same route are an error" do
      # `/v1/widgets/{id}` and `/v1/widgets/{name}` are one route to a client.
      # If the check cannot see them as one, it reports a phantom route forever;
      # if it can, it is blind to a collision. So the reader refuses the
      # ambiguity rather than picking a winner.
      defmodule CollidingRouter do
        def __routes__ do
          [
            %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :a},
            %{verb: :get, path: "/v1/widgets/:name", plug: Enum, plug_opts: :b}
          ]
        end
      end

      assert_raise RuntimeError, ~r/both read as GET \/v1\/widgets\/\{\}/, fn ->
        Paths.router_operations!(CollidingRouter)
      end
    end
  end

  describe "the comparison, pointed at an injected fault" do
    # Each of these injects one fault and asserts the checker names it. This is
    # the test that a checker pointed the wrong way cannot pass: if the
    # comparison reported drift in the wrong direction, or none at all, the
    # assertion below that expects the offender would fail.

    defp document_for(lines), do: lines |> write_document() |> Paths.document_operations!()

    # A module with the one function the reader looks for. Built rather than
    # written out so a test can change the route set without changing the fixture
    # — a hand-written module per case is a hand-maintained list wearing a
    # disguise, which is the thing this whole check is against.
    defp router_for(routes) do
      module = :"FaultRouter#{System.unique_integer([:positive])}"

      Module.create(
        module,
        {:def, [], [{:__routes__, [], nil}, [do: Macro.escape(routes)]]},
        Macro.Env.location(__ENV__)
      )

      Paths.router_operations!(module)
    end

    defp widget_routes do
      [
        %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
        %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}
      ]
    end

    test "a document path the router does not serve is reported, and named" do
      document =
        document_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "  /v1/widgets/{id}:",
          "    get:",
          "  /v1/gadgets:",
          "    get:"
        ])

      router = router_for(widget_routes())

      diff = Paths.diff(document, router, %{})

      assert [%{"label" => "GET /v1/gadgets"}] = diff.documented_not_served
      assert diff.served_not_documented == []
    end

    test "a router path the document omits is reported, and named" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for(widget_routes())

      diff = Paths.diff(document, router, %{})

      assert [%{"label" => "GET /v1/widgets/:id"}] = diff.served_not_documented
      assert diff.documented_not_served == []
    end

    test "a renamed path is reported on both sides, not on whichever one moved" do
      # A count comparison passes here: two operations become two operations.
      # Comparing the paths does not, and the offender appears twice — once for
      # the document's spelling, once for the router's.
      document =
        document_for([
          "paths:",
          "  /v1/widgets:",
          "    get:",
          "  /v1/wodgets/{id}:",
          "    get:"
        ])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}
        ])

      diff = Paths.diff(document, router, %{})

      assert Enum.map(diff.documented_not_served, & &1["label"]) == ["GET /v1/wodgets/{id}"]
      assert Enum.map(diff.served_not_documented, & &1["label"]) == ["GET /v1/widgets/:id"]
    end

    test "a method added to one side only is drift, even though the path matches" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for([%{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list}])

      router_with_delete =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :delete, path: "/v1/widgets", plug: Enum, plug_opts: :remove}
        ])

      assert Paths.diff(document, router, %{}).served_not_documented == []

      assert [%{"label" => "DELETE /v1/widgets"}] =
               Paths.diff(document, router_with_delete, %{}).served_not_documented
    end

    test "a renamed path parameter is not drift" do
      document = document_for(["paths:", "  /v1/widgets/{widget_id}:", "    get:"])

      router =
        router_for([%{verb: :get, path: "/v1/widgets/:id", plug: Enum, plug_opts: :show}])

      diff = Paths.diff(document, router, %{})

      assert diff.documented_not_served == []
      assert diff.served_not_documented == []
    end

    test "an exclusion covers the route it names, and the difference says so" do
      # A named carve-out is how a real omission stays a real omission. It has to
      # be narrow: the same omission with a different path, or with a different
      # method, is drift again. And the reason has to survive into the report,
      # or a carve-out reads as a gap the check happened to miss.
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/healthz", plug: Enum, plug_opts: :healthz}
        ])

      excluded = %{Paths.normalise_operation("GET", "/healthz") => "an infrastructure probe"}
      diff = Paths.diff(document, router, excluded)

      assert [%{"label" => "GET /healthz"}] = diff.served_not_documented
      assert diff.unexplained == []

      assert [%{"label" => "GET /healthz", "reason" => "an infrastructure probe"}] = diff.excluded

      assert Paths.describe_drift(diff) =~ "GET /healthz — an infrastructure probe"
    end

    test "an exclusion does not carry over to another method on the same path" do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])

      router =
        router_for([
          %{verb: :get, path: "/v1/widgets", plug: Enum, plug_opts: :list},
          %{verb: :get, path: "/healthz", plug: Enum, plug_opts: :healthz},
          %{verb: :delete, path: "/healthz", plug: Enum, plug_opts: :remove}
        ])

      excluded = %{Paths.normalise_operation("GET", "/healthz") => "an infrastructure probe"}
      diff = Paths.diff(document, router, excluded)

      assert Enum.map(diff.served_not_documented, & &1["label"]) == [
               "DELETE /healthz",
               "GET /healthz"
             ]

      assert [%{"label" => "DELETE /healthz"}] = diff.unexplained
      assert [%{"label" => "GET /healthz"}] = diff.excluded
    end
  end

  describe "the failure message" do
    setup do
      document = document_for(["paths:", "  /v1/widgets:", "    get:"])
      router = router_for([%{verb: :delete, path: "/v1/widgets", plug: Enum, plug_opts: :remove}])

      %{message: Paths.describe_drift(Paths.diff(document, router, %{}))}
    end

    test "it names the path, and says which side has it", %{message: message} do
      assert message =~ "openapi.yaml documents 1 operation the router does not serve."
      assert message =~ "GET /v1/widgets"
      assert message =~ "CourierWeb.Router serves 1 operation openapi.yaml does not describe."
      assert message =~ "DELETE /v1/widgets"
    end

    test "it says what to do, in both directions", %{message: message} do
      assert message =~ "add it to `lib/courier_web/router.ex`"
      assert message =~ "delete it from `openapi.yaml`"
      assert message =~ "document it in `openapi.yaml`"
    end

    test "it says why that direction matters, in the direction that 404s a client", %{
      message: message
    } do
      assert message =~ "An endpoint in the menu that answers 404 is a product configured"
    end

    test "it says who serves a router operation, so the next person does not have to grep", %{
      message: message
    } do
      assert message =~ "served by Enum.remove/2"
    end

    test "it points at the two files involved", %{message: message} do
      assert message =~ "test/courier_web/openapi_document_test.exs"
      assert message =~ "test/courier_web/openapi_paths_test.exs"
    end
  end
end
