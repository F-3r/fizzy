require "test_helper"
require "fizzy_client"
require "socket"
require "net/http"

class FizzyClientIntegrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  BASE_ACCOUNT_SLUG = ActiveRecord::FixtureSet.identify("37signals").to_s
  WRITEBOOK_BOARD_ID = ActiveRecord::FixtureSet.identify("writebook", :uuid).to_s
  WRITEBOOK_TRIAGE_COLUMN_ID = ActiveRecord::FixtureSet.identify("writebook_triage", :uuid).to_s
  DAVID_TOKEN = "x18cf1425682700098f24f0799e3fe20"
  DAVID_USER_ID = ActiveRecord::FixtureSet.identify("david", :uuid).to_s
  FILE_FIXTURE_PATH = Rails.root.join("test/fixtures/files/avatar.png")

  class << self
    def live_base_url
      @live_base_url ||= begin
        port = 4300 + (ENV.fetch("TEST_ENV_NUMBER", "0").to_i * 10) + (Process.pid % 10)
        log_path = Rails.root.join("tmp/fizzy_client_test_server_#{port}.log")
        pid = spawn({ "RAILS_ENV" => "test" }, Rails.root.join("bin/rails").to_s, "server", "-p", port.to_s, out: log_path.to_s, err: log_path.to_s)
        at_exit do
          begin
            Process.kill("TERM", pid)
            Process.wait(pid)
          rescue Errno::ESRCH, Errno::ECHILD
          end
        end
        wait_for_server!(port, log_path)
        "http://127.0.0.1:#{port}"
      end
    end

    def wait_for_server!(port, log_path)
      deadline = Time.now + 40
      uri = URI("http://127.0.0.1:#{port}/up")

      loop do
        begin
          response = Net::HTTP.get_response(uri)
          return if response.is_a?(Net::HTTPSuccess)
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        end

        raise "Fizzy test server did not boot. See #{log_path}" if Time.now >= deadline
        sleep 0.5
      end
    end
  end

  setup do
    @client = Fizzy::Client.new(
      base_url: self.class.live_base_url,
      bearer_token: DAVID_TOKEN,
      account_slug: BASE_ACCOUNT_SLUG,
      user_agent: "fizzy-client-test"
    )
  end

  test "identity and low level request use bearer auth over real http" do
    identity = @client.get_identity
    boards = @client.request(method: :get, path: "/#{BASE_ACCOUNT_SLUG}/boards", query: { page: 1 })
    unauthorized = Fizzy::Client.new(base_url: self.class.live_base_url, bearer_token: "nope", account_slug: BASE_ACCOUNT_SLUG).list_boards

    assert_predicate identity, :success?
    assert_equal identities(:david).id, identity.body["id"]
    assert_predicate boards, :success?
    assert boards.body.any? { |board| board["id"] == WRITEBOOK_BOARD_ID }
    assert_equal 401, unauthorized.status
  end

  test "boards columns cards and comments work end to end" do
    board = @client.create_board(name: "Fizzy Client Test Board #{SecureRandom.hex(4)}", all_access: true)
    assert_equal 201, board.status
    board_id = board.body.fetch("id")

    fetched_board = @client.get_board(board_id: board_id)
    assert_equal board_id, fetched_board.body["id"]

    updated_board = @client.update_board(board_id: board_id, name: "Renamed Board")
    assert_predicate updated_board, :success?
    assert_equal "Renamed Board", updated_board.body["name"]

    column = @client.create_column(board_id: board_id, name: "Doing", color: "var(--color-card-1)")
    assert_equal 201, column.status
    column_id = column.body.fetch("id")

    listed_columns = @client.list_columns(board_id: board_id)
    assert listed_columns.body.any? { |entry| entry["id"] == column_id }

    updated_column = @client.update_column(board_id: board_id, column_id: column_id, name: "Done")
    assert_predicate updated_column, :success?
    assert_equal "Done", updated_column.body["name"]

    card = @client.create_card(board_id: board_id, title: "Imported card", description: "<p>Original</p>")
    assert_equal 201, card.status
    card_number = card.body.fetch("number")

    fetched_card = @client.get_card(card_number: card_number)
    assert_equal "Imported card", fetched_card.body["title"]

    triaged = @client.triage_card(card_number: card_number, column_id: column_id)
    assert_equal 204, triaged.status
    in_column = @client.get_card(card_number: card_number)
    assert_equal column_id, in_column.body.dig("column", "id")

    comment = @client.create_comment(card_number: card_number, body: "<p>Hello from client</p>")
    assert_equal 201, comment.status
    comment_id = comment.body.fetch("id")

    listed_comments = @client.list_comments(card_number: card_number)
    assert listed_comments.body.any? { |entry| entry["id"] == comment_id }

    updated_comment = @client.update_comment(card_number: card_number, comment_id: comment_id, body: "<p>Updated comment</p>")
    assert_predicate updated_comment, :success?
    assert_equal "Updated comment", updated_comment.body.dig("body", "plain_text")

    closed = @client.close_card(card_number: card_number)
    assert_equal 204, closed.status
    assert @client.get_card(card_number: card_number).body["closed"]

    reopened = @client.reopen_card(card_number: card_number)
    assert_equal 204, reopened.status
    assert_not @client.get_card(card_number: card_number).body["closed"]

    untriaged = @client.untriage_card(card_number: card_number)
    assert_equal 204, untriaged.status
    assert_nil @client.get_card(card_number: card_number).body["column"]

    moved = @client.move_card_to_board(card_number: card_number, board_id: WRITEBOOK_BOARD_ID)
    assert_predicate moved, :success?
    assert_equal WRITEBOOK_BOARD_ID, moved.body.dig("board", "id")

    deleted_comment = @client.delete_comment(card_number: card_number, comment_id: comment_id)
    assert_equal 204, deleted_comment.status

    deleted_card = @client.delete_card(card_number: card_number)
    assert_equal 204, deleted_card.status
    assert_equal 404, @client.get_card(card_number: card_number).status

    assert_equal 204, @client.delete_column(board_id: board_id, column_id: column_id).status
    assert_equal 204, @client.delete_board(board_id: board_id).status
  end

  test "users can be listed fetched updated and deactivated over real http" do
    admin_identity = Identity.create!(email_address: "fizzy-client-admin-#{SecureRandom.hex(4)}@example.com")
    admin_user = User.create!(name: "API Admin", role: :admin, identity: admin_identity, account: accounts("37s"), verified_at: Time.current)
    admin_token = admin_identity.access_tokens.create!(description: "Fizzy Client Admin", permission: :write).token
    admin_client = Fizzy::Client.new(base_url: self.class.live_base_url, bearer_token: admin_token, account_slug: BASE_ACCOUNT_SLUG)

    temp_identity = Identity.create!(email_address: "fizzy-client-#{SecureRandom.hex(4)}@example.com")
    temp_user = User.create!(name: "API Temp User", role: :member, identity: temp_identity, account: accounts("37s"), verified_at: Time.current)

    listed_users = @client.list_users
    assert_predicate listed_users, :success?
    assert listed_users.body.any? { |user| user["id"] == DAVID_USER_ID }

    fetched_user = admin_client.get_user(user_id: temp_user.id)
    assert_equal "API Temp User", fetched_user.body["name"]

    updated_user = admin_client.update_user(user_id: temp_user.id, name: "API Updated User")
    assert_predicate updated_user, :success?
    assert_equal "API Updated User", updated_user.body["name"]

    deleted_user = admin_client.delete_user(user_id: temp_user.id)
    assert_equal 204, deleted_user.status
    assert_equal 404, admin_client.get_user(user_id: temp_user.id).status
  ensure
    admin_user&.destroy!
    admin_identity&.destroy!
    temp_user&.destroy!
    temp_identity&.destroy!
  end

  test "direct upload and attachment helpers work end to end" do
    upload = @client.upload_attachment_and_build_tag(path: FILE_FIXTURE_PATH.to_s)
    assert_predicate upload, :success?
    assert upload.body["signed_id"].present?
    assert upload.body["attachable_sgid"].present?
    assert_includes upload.body["attachment_html"], upload.body["attachable_sgid"]

    card = @client.create_card(
      board_id: WRITEBOOK_BOARD_ID,
      title: "Attachment card #{SecureRandom.hex(4)}",
      description: @client.append_attachments_to_html("<p>See file</p>", attachments: [ upload.body ])
    )
    assert_equal 201, card.status
    assert card.body["has_attachments"]

    assert_equal 204, @client.delete_card(card_number: card.body.fetch("number")).status
  end

  test "missing records and validation failures still return response objects" do
    admin_identity = Identity.create!(email_address: "fizzy-client-invalid-admin-#{SecureRandom.hex(4)}@example.com")
    admin_user = User.create!(name: "Validation Admin", role: :admin, identity: admin_identity, account: accounts("37s"), verified_at: Time.current)
    admin_token = admin_identity.access_tokens.create!(description: "Validation Admin Token", permission: :write).token
    admin_client = Fizzy::Client.new(base_url: self.class.live_base_url, bearer_token: admin_token, account_slug: BASE_ACCOUNT_SLUG)

    temp_identity = Identity.create!(email_address: "fizzy-client-invalid-#{SecureRandom.hex(4)}@example.com")
    temp_user = User.create!(name: "Validation User", role: :member, identity: temp_identity, account: accounts("37s"), verified_at: Time.current)

    missing = @client.get_board(board_id: "missing")
    invalid = admin_client.update_user(user_id: temp_user.id, name: "")

    assert_equal 404, missing.status
    assert_predicate missing, :error?
    assert_equal 422, invalid.status
    assert_predicate invalid, :error?
  ensure
    admin_user&.destroy!
    admin_identity&.destroy!
    temp_user&.destroy!
    temp_identity&.destroy!
  end
end
