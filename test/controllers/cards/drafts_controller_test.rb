require "test_helper"

class Cards::DraftsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "show" do
    card = boards(:writebook).cards.create!(creator: users(:kevin), status: :drafted)

    get card_draft_path(card)
    assert_response :success
    assert_select ".card__initial-status", text: /Backlog/
    assert_select ".card__initial-status template input[name='column_id'][form='#{dom_id(card, :publish_form)}']"
    assert_select ".card__initial-status [role='checkbox'][data-combobox-value='']", text: /Backlog/
    assert_select ".card__initial-status [role='checkbox'][data-combobox-value='#{columns(:writebook_in_progress).id}']", text: /In progress/
  end

  test "show redirects to card when published" do
    card = cards(:logo)

    get card_draft_path(card)
    assert_redirected_to card
  end
end
