defmodule CourierWeb.NotificationPreferencesControllerTest do
  @moduledoc """
  The JSON API over notification preferences, and the error envelope core
  requires around it: `application/problem+json`, a stable code, a `trace_id`
  that matches the `X-Trace-Id` header, and per-field errors on a 422.

  courier does not authenticate these requests in this packet — there is no JWT
  verification here yet — so these tests are about shape and semantics, not
  about who is allowed to ask.
  """

  use CourierWeb.ConnCase, async: true

  @user_id "6f5d4c3b-2a19-4e8f-9c07-1b2d3e4f5061"

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp problem(conn) do
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/problem+json"

    body(conn)
  end

  defp get_preferences(conn, user_id) do
    conn
    |> get("/v1/notification_preferences/#{user_id}")
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp put_preferences(conn, user_id, params) do
    put(conn, "/v1/notification_preferences/#{user_id}", params)
  end

  describe "GET /v1/notification_preferences/:user_id" do
    test "answers 200 with every notification type, on, for a user with no rows" do
      conn = get(build_conn(), "/v1/notification_preferences/#{@user_id}")

      assert %{"data" => %{"user_id" => @user_id, "preferences" => preferences}} = body(conn)

      assert Enum.map(preferences, & &1["notification_type"]) ==
               ~w(welcome password_reset team_invitation)

      assert Enum.all?(preferences, &(&1["email_enabled"] and &1["push_enabled"]))
    end

    test "answers with what the user actually stored" do
      put_preferences(build_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(build_conn(), @user_id)

      by_type = Map.new(preferences, &{&1["notification_type"], &1})
      assert by_type["welcome"]["email_enabled"] == false
      assert by_type["welcome"]["push_enabled"] == true
      assert by_type["password_reset"]["email_enabled"] == true
    end

    test "a user id that is not a uuid is a 422, not a 500" do
      conn = get(build_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)

      assert %{"errors" => [%{"field" => "user_id", "code" => "invalid_format"}]} = problem(conn)
    end

    test "an unknown user is not a 404: courier does not own users, so there is nothing to find" do
      # identity owns the user table. A user courier has never seen is the normal
      # case here, not an error, and a 404 would be courier claiming to know
      # something about the requester it does not know.
      conn =
        get(build_conn(), "/v1/notification_preferences/00000000-0000-0000-0000-000000000000")

      assert conn.status == 200
      assert %{"data" => %{"preferences" => [_welcome, _reset, _invitation]}} = body(conn)
    end
  end

  describe "PUT /v1/notification_preferences/:user_id" do
    test "turns one channel off and answers with the stored state" do
      conn =
        put_preferences(build_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
        })

      assert %{"data" => %{"user_id" => @user_id, "preferences" => preferences}} = body(conn)

      welcome = Enum.find(preferences, &(&1["notification_type"] == "welcome"))
      assert welcome["email_enabled"] == false
    end

    test "the change is visible to the next GET" do
      put_preferences(build_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "team_invitation", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(build_conn(), @user_id)

      assert Enum.find(preferences, &(&1["notification_type"] == "team_invitation"))[
               "email_enabled"
             ] ==
               false
    end

    test "is idempotent: the same request twice is the same answer" do
      params = %{"preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]}

      first = body(put_preferences(build_conn(), @user_id, params))
      second = body(put_preferences(build_conn(), @user_id, params))

      assert first == second
    end

    test "one user's change does not touch another's" do
      other = "7a6e5d4c-3b20-4f90-8d18-2c3e4f506172"

      put_preferences(build_conn(), @user_id, %{
        "preferences" => [%{"notification_type" => "welcome", "email_enabled" => false}]
      })

      assert %{"data" => %{"preferences" => preferences}} = get_preferences(build_conn(), other)
      assert Enum.find(preferences, &(&1["notification_type"] == "welcome"))["email_enabled"]
    end

    test "a preference courier does not send is a 422 naming the field" do
      conn =
        put_preferences(build_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "weekly_digest", "email_enabled" => false}]
        })

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)

      assert [%{"field" => "preferences[0].notification_type"}] = body(conn)["errors"]
    end

    test "a channel courier does not have is a 422, not a silently ignored typo" do
      conn =
        put_preferences(build_conn(), @user_id, %{
          "preferences" => [%{"notification_type" => "welcome", "emai_enabled" => false}]
        })

      assert %{"code" => "validation_failed"} = problem(conn)
      assert [%{"field" => "preferences[0].emai_enabled"}] = body(conn)["errors"]
    end

    test "a rejected batch stores nothing" do
      conn =
        put_preferences(build_conn(), @user_id, %{
          "preferences" => [
            %{"notification_type" => "welcome", "email_enabled" => false},
            %{"notification_type" => "nope"}
          ]
        })

      assert conn.status == 422

      assert %{"data" => %{"preferences" => preferences}} =
               get_preferences(build_conn(), @user_id)

      assert Enum.all?(preferences, & &1["email_enabled"])
    end

    test "a body that is not a list of preferences is a 422" do
      conn = put_preferences(build_conn(), @user_id, %{"preferences" => "welcome"})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
      assert [%{"field" => "preferences"}] = body(conn)["errors"]
    end

    test "an empty body is a 422" do
      conn = put_preferences(build_conn(), @user_id, %{})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
    end

    test "a malformed body is a 400, because the client could not have known" do
      # The content-type goes on before the body: `put/3` with a binary body
      # refuses to build a request that has not said what the body is, and it
      # would raise in the test process before courier ever saw the request.
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put("/v1/notification_preferences/#{@user_id}", "{not json")

      assert %{"code" => "bad_request", "status" => 400} = problem(conn)
    end

    test "a user id that is not a uuid is a 422 before the body is looked at" do
      conn = put_preferences(build_conn(), "not-a-uuid", %{"preferences" => []})

      assert %{"code" => "validation_failed", "status" => 422} = problem(conn)
    end
  end

  describe "the error envelope" do
    test "is core's problem+json, with a stable type URI and a code that matches it" do
      conn = put_preferences(build_conn(), @user_id, %{"preferences" => []})

      assert %{"type" => type, "code" => "validation_failed"} = problem(conn)
      assert type == "https://errors.cafaye.com/validation_failed"
    end

    test "carries a title, a status, and a detail" do
      conn = put_preferences(build_conn(), @user_id, %{"preferences" => []})

      assert %{"title" => "Validation failed", "status" => 422, "detail" => detail} =
               problem(conn)

      assert is_binary(detail)
    end

    test "names the instance the request was made to" do
      conn = put_preferences(build_conn(), @user_id, %{"preferences" => []})

      assert %{"instance" => "/v1/notification_preferences/" <> @user_id} = problem(conn)
    end

    test "carries a trace_id that matches the X-Trace-Id response header" do
      conn = put_preferences(build_conn(), @user_id, %{"preferences" => []})

      assert %{"trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end

    test "carries the same trace_id for a request that went nowhere" do
      conn = get(build_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end

    test "lists the field that failed, for support to read" do
      conn = get(build_conn(), "/v1/notification_preferences/not-a-uuid")

      assert %{"errors" => [%{"field" => "user_id"}]} = problem(conn)
    end

    test "a 404 for an unknown route is core's envelope too" do
      conn = get(build_conn(), "/v1/nope")

      assert %{"code" => "not_found", "status" => 404, "trace_id" => trace_id} = problem(conn)
      assert [trace_id] == get_resp_header(conn, "x-trace-id")
    end
  end
end
