require "test_helper"

class Command::ConsiderTest < ActionDispatch::IntegrationTest
  include CommandTestHelper

  setup do
    Current.session = sessions(:david)
    @card = cards(:text)
    @card.engage
  end

  test "consider card on perma" do
    assert_changes -> { @card.reload.considering? }, from: false, to: true do
      execute_command "/consider", context_url: collection_card_url(@card.collection, @card)
    end
  end

  test "consider cards on index page" do
    cards = cards(:logo, :text, :layout)
    cards.each(&:engage)

    execute_command "/consider", context_url: collection_cards_url(@card.collection)

    assert cards.map(&:reload).all?(&:considering?)
  end

  test "undo consider" do
    cards = cards(:logo, :text, :layout)
    cards.each(&:engage)

    command = parse_command "/consider", context_url: collection_cards_url(@card.collection)
    command.execute

    assert cards.map(&:reload).all?(&:considering?)

    command.undo

    assert cards.map(&:reload).all?(&:doing?)
  end
end
