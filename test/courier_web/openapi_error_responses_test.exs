defmodule CourierWeb.OpenAPIErrorResponsesTest do
  @moduledoc """
  `openapi.yaml` and courier's endpoint have to agree about **responses**, the way
  `CourierWeb.OpenAPIDocumentTest` holds them to agreeing about paths.

  ## Why this file exists

  courier-12 was opened on a measurement that every operation could return a **500**
  and none of the eight declared one, that every operation could return a **406**
  and none declared it, and that six of core's nine reserved codes appeared
  nowhere in the document. The path check that already existed could not have
  caught any of it, and could not be made to: it compares `{method, path}` sets,
  which are identical whether or not a 500 is declared. This file compares
  statuses, and it compares them in **both** directions, because the two failures
  are different and only one of them is visible.

  A status a client can receive and the document does not describe is a case the
  client handles with whatever its default branch is. A status the document
  describes and the client can never receive is a case a client wrote for nothing,
  and it is the one that reads as tidiness — courier-12 found both, on the same
  file, in the same status.

  ## How it works, and why it is not a list

  The direction *a status the endpoint can return is a status the document
  declares* is checked by **provoking** it and asking. There is no table of
  statuses per operation written down anywhere in this file, because a table is a
  check that can only fail for a case somebody remembered to type. The operations
  come from `Courier.TestSupport.OpenAPIPaths`, the path parameters are filled in
  mechanically, and the statuses come from sending requests to the real endpoint.

  That is also the half a neutral, language-agnostic harness cannot do: it needs a
  running Phoenix, a plug pipeline, and a real `problem+json` body. This is the
  language-specific half, and it is why the document's own path test and this one
  are both kept.

  The other direction — *the document declares nothing courier cannot return* —
  cannot be proved by provoking, because the way to prove a status is unreachable
  is to fail to reach it. It is therefore asserted against a short, named list of
  statuses courier was measured not to send, each with the reason, and each also
  required to appear in the document's own header. A status courier starts
  returning has to be added in the same commit that starts returning it, and this
  test is what makes that a decision rather than a drift.

  `async: true`, like the two document checks it sits beside: it reads a file and
  sends requests through the test adapter, and starts no process the suite shares.
  """

  use CourierWeb.ConnCase, async: true

  alias Courier.TestSupport.OpenAPIPaths, as: Paths

  @document "openapi.yaml"

  @account "6f5d4c3b-2a18-4e8f-9c07-1b2d3e4f5061"
  @id "6f5d4c3b-2a18-4e8f-9c07-1b2d3e4f5061"
  # A well-formed uuid courier has never issued, for the 404 case.
  @missing_id "7f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  # Core's reserved list, verbatim. A code outside it needs a reason in the
  # document; `bad_request` and `not_acceptable` are the two courier carries, and
  # `CourierWeb.Problem`'s moduledoc argues for both.
  @reserved ~w(unauthorized forbidden not_found conflict validation_failed
               rate_limited idempotency_key_reused internal unavailable)
  @extra_codes ~w(bad_request not_acceptable)

  setup_all do
    %{
      responses: Paths.document_responses!(@document),
      components: Paths.component_responses!(@document),
      header: @document |> File.read!() |> String.split("openapi: 3.1.0") |> List.first(),
      router: Paths.router_operations!()
    }
  end

  # --- the completeness direction, one failure class at a time ----------------

  describe "a status the endpoint can return is a status the document declares" do
    test "401 — every operation behind the Principal plug declares it", %{responses: responses} do
      # Proven by asking: an anonymous request to an authenticated operation is
      # 401, and an anonymous request to the two unauthenticated ones is not. So
      # the set of operations that must declare 401 is discovered, not written.
      {must_declare, need_not} =
        responses
        |> Map.keys()
        |> Enum.split_with(fn operation -> provoke(operation, anonymous: true) == 401 end)

      assert must_declare != [],
             "nothing answered 401, so this test proved nothing: either the plug " <>
               "stopped refusing anonymous callers or the probes stopped reaching it"

      assert Enum.all?(must_declare, fn op -> Map.has_key?(responses[op], "401") end),
             undeclared(must_declare, "401", responses)

      # And the two operations that are served unauthenticated must not claim 401,
      # or the document is describing a security control courier does not have.
      for operation <- need_not do
        refute Map.has_key?(responses[operation], "401"),
               "#{label(operation)} answers #{provoke(operation, anonymous: true)} to an " <>
                 "anonymous request, and declares a 401. Core's conventions and courier's " <>
                 "own DECISION NEEDED (courier-05) agree that these two are served " <>
                 "unauthenticated; declaring 401 would be a document lying about auth."
      end
    end

    test "406 — every operation in the :api pipeline declares it", %{responses: responses} do
      unreachable =
        Enum.reject(Map.keys(responses), fn operation ->
          provoke(operation, accept: "text/html") == 406
        end)

      assert unreachable == [],
             "these operations did not answer 406 to `Accept: text/html`, so this test " <>
               "cannot claim 406 is reachable on all of them: #{inspect(unreachable)}"

      undeclared = Enum.filter(Map.keys(responses), &(not Map.has_key?(responses[&1], "406")))

      assert undeclared == [], undeclared(undeclared, "406", responses)
    end

    test "400 — the document and the parser agree, in both directions", %{responses: responses} do
      # Nothing here is written down in advance. Every operation is asked, and the
      # answer is compared to the document — which is the only way to get both
      # directions, and the second one is the half that is easy to miss.
      #
      # `CourierWeb.Plugs.ParseBody` wraps `Plug.Parsers`, which reads a body for
      # `POST`, `PUT`, `PATCH` and `DELETE` and ignores one on every other verb.
      # `DELETE` is the case that reads wrong: a `DELETE` carries no body in any
      # sensible client, so it looks bodyless and a document that omits its 400
      # looks right — until a client that does send one is answered with a body
      # nobody documented. A `GET` is the mirror: a 400 declared there is a case a
      # client writes for and can never run.
      #
      # Both halves of this were real. courier-12's first draft of this test
      # checked only the "declares it" half, passed, and shipped a `DELETE` with
      # an undocumented 400 and a `GET` with a documented one that cannot happen.
      probed =
        for operation <- Map.keys(responses), into: %{} do
          {operation, provoke(operation, malformed_body: true) == 400}
        end

      assert Enum.any?(probed, fn {_op, reachable} -> reachable end),
             "no operation answered 400 to a body that is not JSON, so this test " <>
               "proved nothing: the parser has stopped refusing one"

      for {operation, reachable} <- Enum.sort(probed) do
        declared = Map.has_key?(responses[operation], "400")

        assert declared == reachable,
               "#{label(operation)} #{if declared,
                 do: "declares a 400 a client cannot receive — the parser reads no body " <> "on this verb, so the response is unreachable (openapi.yaml declares " <> "#{inspect(Enum.sort(Map.keys(responses[operation])))})",
                 else: "answers 400 to a body that is not JSON and does not declare it. " <> undeclared([operation], "400", responses)}"
      end
    end

    test "404 — every operation addressing one resource by id declares it", %{
      responses: responses,
      router: router
    } do
      # "Has a path parameter" is read from the ROUTER, not from the document, so
      # the fact under test is not also the thing being checked.
      by_id =
        for {{_method, _path} = operation, route} <- router,
            String.contains?(route["path"], ":"),
            Map.has_key?(responses, operation),
            do: operation

      assert by_id != [], "no route with a path parameter was found, so nothing was checked"

      for operation <- by_id do
        status = provoke(operation, id: @missing_id)

        assert status in [404, 422],
               "#{label(operation)} answered #{status} for an id courier has never issued. " <>
                 "A documented operation has to answer one of the two a client can act on; " <>
                 "anything else is a case this test has to be taught."

        assert Map.has_key?(responses[operation], to_string(status)),
               "#{label(operation)} answers #{status} for an unknown id and does not " <>
                 "declare it. #{undeclared([operation], to_string(status), responses)}"
      end
    end

    test "500 — every operation declares it, because RenderErrors can render it for any of them",
         %{responses: responses} do
      # The structural half, and it is the half that holds for all eight at once:
      # `render_errors` is courier's own JSON module, so Phoenix renders a 500 for
      # *any* raise on *any* route. If that stops being true the failures are not
      # silent, because `CourierWeb.ErrorJSON` is what the next test reads.
      assert render_errors_json?(),
             "CourierWeb.Endpoint is no longer configured to render errors with " <>
               "CourierWeb.ErrorJSON, so a 500 on any route is no longer courier's " <>
               "envelope and this file's 500 claim is no longer true."

      undeclared = Enum.filter(Map.keys(responses), &(not Map.has_key?(responses[&1], "500")))

      assert undeclared == [], undeclared(undeclared, "500", responses)
    end

    test "the 500 body is courier's envelope, with a reserved code", %{responses: responses} do
      # RenderErrors hands `CourierWeb.ErrorJSON` the request's assigns, so calling
      # it directly IS the 500 path, and it needs no database to be taken away and
      # no exception to be provoked.
      body =
        "500.json"
        |> CourierWeb.ErrorJSON.render(%{
          status: 500,
          instance: "/v1/webhook_endpoints",
          trace_id: "0af7651916cd43dd8448eb211c80319c"
        })
        |> Jason.encode!()
        |> Jason.decode!()

      assert body["code"] == "internal"
      assert body["type"] == "https://errors.cafaye.com/internal"
      assert body["status"] == 500
      assert is_binary(body["trace_id"])

      refute Map.has_key?(body, "errors"),
             "core says `errors[]` appears only on a 422, and a 500 that carries one " <>
               "tells a client to look for a field that is not about their request"

      for operation <- Map.keys(responses) do
        assert Map.has_key?(responses[operation], "500"),
               undeclared([operation], "500", responses)
      end
    end
  end

  # --- the envelope, attached -------------------------------------------------

  describe "the envelope is attached to every non-2xx the document declares" do
    test "every non-2xx names application/problem+json", %{responses: responses} do
      bare =
        for {{method, path}, declared} <- responses,
            {status, response} <- declared,
            not success?(status),
            not response.problem_json,
            do: "#{method} #{path} #{status} (openapi.yaml:#{response.line})"

      assert bare == [],
             """
             these non-2xx responses do not name `application/problem+json`, so a client
             that switches on the content type cannot tell they are errors:

             #{Enum.map_join(bare, "\n", &("  " <> &1))}

             This is courier-12's headline finding in its original form: the envelope
             was declared in `components` and wired to nothing. Every non-2xx in this
             document has to name the media type, through a `$ref` that resolves to a
             component that names it.
             """
    end

    test "every non-2xx carries the Problem schema, not merely the media type", %{
      responses: responses
    } do
      bare =
        for {{method, path}, declared} <- responses,
            {status, response} <- declared,
            not success?(status),
            not response.ref_schema,
            do: "#{method} #{path} #{status} (openapi.yaml:#{response.line})"

      assert bare == [],
             """
             these non-2xx responses name the problem media type over some other schema,
             which is a content type promising courier's error shape and delivering
             something else:

             #{Enum.map_join(bare, "\n", &("  " <> &1))}
             """
    end

    test "every reusable response names the envelope, whether or not one points at it", %{
      components: components
    } do
      # The `components.responses` half on its own, so a component can be
      # inspected without an operation pointing at it. A `$ref` to a component that
      # does not exist raises inside the reader rather than arriving here; this is
      # the assertion that the set of components is not silently empty, which is
      # the "declared and referenced by nothing" failure wearing a different hat.
      assert map_size(components) > 0, """
      no reusable response was read from #{@document}. Every non-2xx in this document
      is written as a `$ref` into `components.responses`, so a reader that found none
      would be reporting every non-2xx as unwired and the check above would pass for
      the wrong reason.
      """

      for {name, component} <- components do
        assert component.problem_json,
               "components.responses.#{name} (openapi.yaml:#{component.line}) does not " <>
                 "name `application/problem+json`, and it is what every non-2xx points at"
      end
    end
  end

  # --- the direction that cannot be provoked ----------------------------------

  describe "the document does not declare a status courier cannot return" do
    # Measured, not assumed. Each of these is a status core reserves or names, that
    # courier's endpoint cannot be made to answer, and that the document therefore
    # must not promise. The reasons live in the document's own header and are
    # required to be there, so an omission is an admission rather than a silence.
    #
    # `status => {a short distinctive token, the measured reason in full}`. The
    # assertion is on the token, because the header is a comment block and its
    # sentences are wrapped: matching a whole sentence would fail the first time
    # somebody reflows a comment, which teaches nobody anything. The reason is
    # here so the token is not a mystery.
    @unreachable %{
      "403" => {"Principal", "`CourierWeb.Plugs.Principal` answers 401 and nothing else"},
      "409" => {"taken", "a duplicate url is a 422 whose `errors[0].code` is `taken`, not a 409"},
      "415" => {"pass:", "the parser is configured `pass: [\"*/*\"]` and refuses nothing"},
      "429" => {"no limiter", "thirty rapid writes answer thirty 201s"},
      "503" => {"readyz", "only `GET /readyz` sends it, and that is not an operation"}
    }

    test "no operation declares one", %{responses: responses} do
      declared =
        for {{method, path}, statuses} <- responses,
            status <- Map.keys(statuses),
            Map.has_key?(@unreachable, status),
            do: "#{method} #{path} declares #{status}"

      assert declared == [],
             """
             these operations declare a status courier cannot return:

             #{Enum.map_join(declared, "\n", &("  " <> &1))}

             A document that promises a 409 or a 429 is worse than one that is
             incomplete: a client generated from it will branch on a response that
             never arrives, and a client told to retry on 429 will hammer a service
             that was never rate limiting anything.

             If courier has started returning one of these, the fix is to implement it
             and then say so here — not to delete the line.
             """
    end

    test "and each one is admitted in the document's header", %{header: header} do
      for {status, {token, reason}} <- @unreachable do
        assert header =~ status,
               "#{@document} does not declare #{status} anywhere, which is correct, and " <>
                 "its header does not say why either. #{reason}. An omission the document " <>
                 "does not admit is the silent kind this header exists to prevent."

        assert header =~ token,
               "#{@document} omits #{status} but its header never mentions #{inspect(token)}, " <>
                 "so a reader is told what is missing and not why. The measured reason is: " <>
                 "#{reason}."
      end
    end

    test "Idempotency-Key is absent, because courier does not implement it", %{header: header} do
      # The brief for this packet asked for `Idempotency-Key` on the two mutating
      # POSTs. It is not declared, because it is not implemented, and the
      # measurement is in the header. If a later packet implements it, the header
      # stops being true and this test is where that has to be noticed.
      assert header =~ "Idempotency-Key",
             "#{@document} says nothing about `Idempotency-Key`, and courier accepts the " <>
               "header and ignores it. The gap has to be written down, because a client " <>
               "reading a document that is silent reasonably assumes there is no gap."

      assert header =~ "does not",
             "#{@document} mentions `Idempotency-Key` without saying courier ignores it"
    end
  end

  # --- the reserved codes ------------------------------------------------------

  describe "the codes are core's reserved codes, used as core says" do
    test "the document has examples to check, so the two checks below are not vacuous" do
      assert length(examples()) > 0,
             "no `example:` was read from #{@document}. Every reusable response ships " <>
               "one, and a check over none is a check that cannot fail."
    end

    test "every example's code is the last segment of its type" do
      for %{line: line, type: type, code: code} <- examples() do
        assert type |> String.split("/") |> List.last() == code,
               "openapi.yaml:#{line} has an example whose `code` is #{inspect(code)} and " <>
                 "whose `type` ends in #{inspect(type)}. Core says `code` is the last " <>
                 "segment of `type`, in snake_case, and a client that branches on `code` " <>
                 "is reading the one of the two that this document has to keep right."
      end
    end

    test "every example's code is one CourierWeb.Problem can actually emit" do
      known = @reserved ++ @extra_codes

      for %{line: line, code: code} <- examples() do
        assert code in known,
               "openapi.yaml:#{line} promises the code #{inspect(code)}, and " <>
                 "`CourierWeb.Problem` has no such code, so no error courier can send will " <>
                 "ever carry it. A code a client handles and courier cannot send is a " <>
                 "branch that never runs. The codes courier can emit are: " <>
                 "#{Enum.join(known, ", ")}."
      end
    end

    test "every non-2xx courier really sends satisfies the same rule", %{responses: responses} do
      # Asked of the running service rather than read out of the document, so this
      # fails if `CourierWeb.Problem` and the document ever part ways — including
      # in the direction no document check can see, where courier sends a code or
      # a trace id the document never promised.
      #
      # One probe per status, each shaped to reach that status and no other: a
      # request with a bad `Accept` never gets as far as being parsed, so a single
      # probe cannot stand in for four.
      probes = [
        {400, [malformed_body: true]},
        {401, [anonymous: true]},
        {404, [id: @missing_id]},
        {422, [id: @missing_id, anonymous: true, malformed_body: true]}
      ]

      provoked =
        for {status, opts} <- probes,
            operation <- Map.keys(responses),
            conn = safe_conn_for(operation, opts),
            conn.status == status,
            do: {operation, conn}

      assert provoked != [],
             "no provoked request produced one of the statuses under test, so this " <>
               "test proved nothing: the probes have stopped reaching the endpoint."

      for {operation, conn} <- provoked do
        assert problem_json?(conn),
               "#{label(operation)} answered #{conn.status} as " <>
                 "#{inspect(Plug.Conn.get_resp_header(conn, "content-type"))}, and a client " <>
                 "that switches on the content type reads an error as a success"

        payload = body(conn)

        assert payload["code"] == payload["type"] |> String.split("/") |> List.last(),
               "#{label(operation)} answered #{conn.status} with `code` " <>
                 "#{inspect(payload["code"])} and `type` #{inspect(payload["type"])}. Core " <>
                 "says `code` is the last segment of `type`, and a client branching on " <>
                 "`code` is reading one of the two."

        assert payload["code"] in (@reserved ++ @extra_codes),
               "#{label(operation)} answered #{conn.status} with `code` " <>
                 "#{inspect(payload["code"])}, which is not a code `CourierWeb.Problem` " <>
                 "documents, and therefore not one a client can be told to expect"

        assert is_binary(payload["trace_id"]) and payload["trace_id"] != "",
               "#{label(operation)} answered #{conn.status} with no `trace_id`, and core " <>
                 "says it is always present"

        assert payload["trace_id"] ==
                 Plug.Conn.get_resp_header(conn, "x-trace-id") |> List.first(),
               "#{label(operation)} answered #{conn.status} with a `trace_id` that does not " <>
                 "match its X-Trace-Id header, and core says support starts from that id"
      end
    end

    test "a 406 carries `not_acceptable`, not `internal`" do
      # `Phoenix.NotAcceptableError` carries no conn, so the response RenderErrors
      # sends for a 406 cannot be observed through ConnTest at all — the exception
      # escapes before the response lands anywhere. What *is* checkable is the
      # function the 406 is rendered from, and it is the same one every other status
      # goes through, so this is not a weaker claim about a different thing.
      #
      # It is here because the 406 used to fall through to the `:internal` default
      # and tell a client that had asked for `text/html` that courier had failed —
      # with the one code every generated client retries. `internal` is core's
      # reserved slug for 500.
      assert CourierWeb.Problem.for_status(406) == :not_acceptable
      assert CourierWeb.Problem.for_code(:not_acceptable) == {406, "Not acceptable"}
    end

    test "every status courier can answer has its own code, not the `internal` fallback" do
      # `Problem.for_status/1` falls back to `:internal` for a status with no code
      # of its own, which is a reasonable last resort and a bad default answer:
      # the slug then says 500 for something that is not a 500. Every status the
      # probes above reached is in the table, so none of them is wearing it.
      for status <- [400, 401, 404, 406, 422, 500] do
        assert CourierWeb.Problem.for_status(status) != :internal or status == 500,
               "#{status} resolves to the `internal` code, so a client branching on " <>
                 "`code` is told courier failed internally whatever actually happened"
      end
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp success?("2" <> _), do: true
  defp success?(_), do: false

  defp label({method, path}), do: "#{method} #{path}"

  defp undeclared(operations, status, responses) do
    """
    #{Enum.map_join(operations, "\n", fn op -> "  #{label(op)} answers #{status} and does not declare it (openapi.yaml declares " <> "#{inspect(Enum.sort(Map.keys(responses[op])))})" end)}

    A status a client can receive and the document does not describe is a case the
    client has to handle with no documentation: a generated client falls through to
    whatever its default branch is, and courier's envelope is the shape that branch
    will receive.
    """
  end

  # Every path parameter filled with a real uuid, mechanically.
  defp fill(path, id), do: String.replace(path, ~r/\{[^}]+\}/, id)

  # Send a request to an operation, with the shape the case needs.
  defp conn_for({method, path}, opts) do
    url = fill(path, Keyword.get(opts, :id, @id))
    conn = build_conn()

    conn =
      if Keyword.get(opts, :anonymous, false) do
        conn
      else
        put_req_header(conn, "x-courier-account", @account)
      end

    conn =
      if accept = opts[:accept] do
        put_req_header(conn, "accept", accept)
      else
        conn
      end

    if opts[:malformed_body] do
      conn
      |> put_req_header("content-type", "application/json")
      |> send(method, url, "{not json")
    else
      send(conn, method, url)
    end
  end

  # The status, and nothing else, for a provoked request.
  #
  # `Phoenix.NotAcceptableError` is the one status ConnTest cannot hand back: it is
  # raised by the `:accepts` plug and carries no conn, so the response RenderErrors
  # sends never reaches the caller. The exception carries `plug_status`, which is
  # Phoenix's own statement of what it is about to answer, so that is read rather
  # than guessed — and the shape the client receives for a 406 was measured over a
  # real socket, which is the only place a rendered 406 is visible at all.
  defp safe_conn_for(operation, opts) do
    operation |> conn_for(opts)
  rescue
    Phoenix.NotAcceptableError -> nil
  end

  defp provoke(operation, opts) do
    operation |> conn_for(opts) |> Map.fetch!(:status)
  rescue
    error in [Phoenix.NotAcceptableError] -> error.plug_status
  end

  # `Phoenix.ConnTest`'s verb helpers cannot express a `DELETE` with a body —
  # `delete/2` takes a path and nothing else — and that is precisely the case this
  # file has to be able to ask about, because the parser does read a `DELETE` body
  # and answers 400 for one. So a request with a body goes through `dispatch/5`,
  # which takes the verb as an argument, and one without goes through the verb
  # helper, which is what every other probe wants.
  defp send(conn, method, url), do: send(conn, method, url, nil)

  defp send(conn, method, url, nil) do
    case String.upcase(method) do
      "GET" -> get(conn, url)
      "POST" -> post(conn, url, %{})
      "PUT" -> put(conn, url, %{})
      "PATCH" -> patch(conn, url, %{})
      "DELETE" -> delete(conn, url)
    end
  end

  defp send(conn, method, url, body) do
    Phoenix.ConnTest.dispatch(conn, CourierWeb.Endpoint, method_atom(method), url, body)
  end

  # `dispatch/5` wants the verb as an atom, and the operations are keyed by the
  # uppercase string, so the conversion is here rather than at each call site.
  defp method_atom(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp problem_json?(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> List.first()
    |> Kernel.||("")
    |> String.starts_with?("application/problem+json")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Every `example:` courier ships for an error, as `%{line:, type:, code:}`. Scoped
  # to the `components.responses` block, because the same indentation inside the
  # `Problem` schema also spells `type: object` and a schema property is not an
  # example of an error. Line numbers are the document's own, because a failure
  # that names line 412 of a sixty-line slice names nothing.
  defp examples do
    reusable_response_lines()
    |> Enum.reduce({[], nil}, fn
      {line, number}, {found, nil} ->
        if problem_type?(line),
          do: {found, {number, String.replace_prefix(String.trim(line), "type: ", "")}},
          else: {found, nil}

      {line, _number}, {found, {type_line, type}} ->
        if String.starts_with?(String.trim(line), "code: "),
          do: {found ++ [%{line: type_line, type: type, code: code_of(line)}], nil},
          else: {found, {type_line, type}}
    end)
    |> elem(0)
  end

  # The `responses:` block under `components:`, as `{line, number}`, keeping only
  # what is at or below that key's own level.
  defp reusable_response_lines do
    indexed = @document |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    case Enum.find(indexed, fn {line, _n} -> line == "  responses:" end) do
      nil ->
        []

      {_line, number} ->
        indexed
        |> Enum.drop(number)
        |> Enum.take_while(fn {line, _n} ->
          String.trim(line) == "" or String.starts_with?(line, "    ")
        end)
    end
  end

  # `type: https://errors.cafaye.com/<something>` at the example's own level. A
  # `type:` that is not one of these is a schema's, not an error's.
  defp problem_type?(line) do
    trimmed = String.trim(line)

    String.starts_with?(trimmed, "type: https://errors.cafaye.com/") and
      not String.starts_with?(line, "              ")
  end

  defp code_of(line) do
    line |> String.trim() |> String.replace_prefix("code: ", "") |> String.trim("\"")
  end

  defp render_errors_json? do
    :courier
    |> Application.get_env(CourierWeb.Endpoint, [])
    |> Keyword.get(:render_errors, [])
    |> Keyword.get(:formats, [])
    |> Keyword.get(:json) == CourierWeb.ErrorJSON
  end
end
