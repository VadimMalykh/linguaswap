defmodule LinguaswapWeb.UserRegistrationControllerTest do
  use LinguaswapWeb.ConnCase, async: true

  import Linguaswap.AccountsFixtures

  describe "GET /email/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/email/register")
      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ ~p"/email/log-in"
      assert response =~ ~p"/email/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/email/register")

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /email/register" do
    @tag :capture_log
    test "creates account but does not log in", %{conn: conn} do
      email = unique_user_email()

      conn =
        post(conn, ~p"/email/register", %{
          "user" => valid_user_attributes(email: email)
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/email/log-in"

      assert conn.assigns.flash["info"] =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/email/register", %{
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Register"
      assert response =~ "must have the @ sign and no spaces"
    end
  end
end
