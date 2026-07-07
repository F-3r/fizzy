require "test_helper"
require "fizzy_client"

class FizzyClientTest < ActiveSupport::TestCase
  test "synthetic response reports validation errors without raising" do
    client = Fizzy::Client.new(base_url: "http://example.test", bearer_token: "token")

    response = client.create_board(name: "No account")

    assert_equal 0, response.status
    assert_predicate response, :error?
    assert_equal "missing_account_slug", response.body["error"]
    assert_match(/account slug/i, response.message)
  end

  test "request returns synthetic response for connection failures" do
    client = Fizzy::Client.new(base_url: "http://127.0.0.1:1", bearer_token: "token", account_slug: "1234567", open_timeout: 0.2, read_timeout: 0.2)

    response = client.get_identity

    assert_equal 0, response.status
    assert_predicate response, :error?
    assert_equal "connection_failed", response.body["error"]
    assert_kind_of String, response.body["message"]
  end

  test "response parses json and normalizes headers" do
    response = Fizzy::Response.new(
      status: 200,
      headers: { "content-type" => "application/json; charset=utf-8" },
      raw_body: '{"ok":true,"message":"hi"}'
    )

    assert_predicate response, :success?
    assert_predicate response, :json?
    assert_equal({ "ok" => true, "message" => "hi" }, response.body)
    assert_equal "application/json; charset=utf-8", response.headers["Content-Type"]
    assert_equal "hi", response.message
  end

  test "response keeps non json bodies as raw strings" do
    response = Fizzy::Response.new(
      status: 200,
      headers: { "content-type" => "text/plain" },
      raw_body: "uploaded"
    )

    assert_not_predicate response, :json?
    assert_equal "uploaded", response.body
    assert_equal "uploaded", response.raw_body
  end

  test "rich text attachment helpers build and append tags" do
    client = Fizzy::Client.new(base_url: "http://example.test", bearer_token: "token", account_slug: "1234567")

    tag = client.build_rich_text_attachment(signed_id: "sgid-123")
    html = client.append_attachments_to_html("<p>Hello</p>", attachments: [ "sgid-123", tag, { "signed_id" => "sgid-456" } ])

    assert_equal '<action-text-attachment sgid="sgid-123"></action-text-attachment>', tag
    assert_includes html, "<p>Hello</p>"
    assert_equal 2, html.scan("sgid=\"sgid-123\"").size
    assert_includes html, 'sgid="sgid-456"'
  end

  test "attachment upload helper validates inputs" do
    client = Fizzy::Client.new(base_url: "http://example.test", bearer_token: "token", account_slug: "1234567")

    response = client.upload_attachment_and_build_tag

    assert_equal 0, response.status
    assert_equal "missing_upload_source", response.body["error"]
  end
end
