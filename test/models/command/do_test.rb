require "test_helper"

class Command::DoTest < ActionDispatch::IntegrationTest
  include CommandTestHelper

  setup do
    Current.session = sessions(:david)
    @card = cards(:text)
    @card.reconsider
  end

  test "do card on perma" do
    assert_changes -> { @card.reload.doing? }, from: false, to: true do
      execute_command "/do", context_url: collection_card_url(@card.collection, @card)
    end
  end

  test "do cards on index page" do
    cards = cards(:logo, :text, :layout)
    cards.each(&:reconsider)

    execute_command "/do", context_url: collection_cards_url(@card.collection)

    assert cards.map(&:reload).all?(&:doing?)
  end

  test "undo do" do
    cards = cards(:logo, :text, :layout)
    cards.each(&:reconsider)

    command = parse_command "/do", context_url: collection_cards_url(@card.collection)
    command.execute

    assert cards.map(&:reload).all?(&:doing?)

    command.undo

    assert cards.map(&:reload).all?(&:considering?)
  end
end
