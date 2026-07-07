require "test_helper"

class Cards::PublishesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "create" do
    card = cards(:logo)
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card)
    end

    assert_nil card.reload.column
    assert_redirected_to card.board
  end

  test "create in selected workflow status" do
    card = cards(:logo)
    card.drafted!
    column = columns(:writebook_in_progress)

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card), params: { column_id: column.id }
    end

    assert_equal column, card.reload.column
    assert_redirected_to card.board
  end

  test "create with blank status uses backlog" do
    card = cards(:logo)
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card), params: { column_id: "" }
    end

    assert_nil card.reload.column
    assert_redirected_to card.board
  end

  test "create as JSON" do
    card = cards(:logo)
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      post card_publish_path(card), as: :json
    end

    assert_response :created
  end

  test "create and add another" do
    card = cards(:logo)
    card.drafted!

    assert_changes -> { card.reload.published? }, from: false, to: true do
      assert_difference -> { Card.count }, +1 do
        post card_publish_path(card, creation_type: "add_another")
      end
    end

    new_card = Card.last
    assert new_card.drafted?
    assert_redirected_to card_draft_path(new_card)
  end
end
