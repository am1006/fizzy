require "test_helper"

class Command::Ai::TranslatorTest < ActionDispatch::IntegrationTest
  include VcrTestHelper

  setup do
    @user= users(:david)
  end

  test "filter by assignments" do
    # List context
    assert_command({ context: { assignee_ids: [ "jz" ] } }, "cards assigned to jz")
    assert_command({ context: { assignee_ids: [ "jz" ] } }, "assigned to jz")
    assert_command({ context: { assignment_status: "unassigned" } }, "unassigned cards")
    assert_command({ context: { assignment_status: "unassigned" } }, "not assigned")
    assert_command({ context: { assignee_ids: [ "jorge" ], terms: [ "performance" ] } }, "cards about performance assigned to jorge")

    # Card context
    assert_command({ context: { assignee_ids: [ "jz" ] } }, "cards assigned to jz", context: :card)
  end

  test "filter by tag" do
    # List context
    assert_command({ context: { tag_ids: [ "design" ] } }, "cards tagged with design")
    assert_command({ context: { tag_ids: [ "design" ] } }, "cards tagged with #design")
    assert_command({ context: { tag_ids: [ "design" ] } }, "#design cards")

    # Card context
    assert_command({ context: { tag_ids: [ "design" ] } }, "cards tagged with design")
  end

  test "filter by indexed_by" do
    # List context
    assert_command({ context: { indexed_by: "closed" } }, "closed cards")
    assert_command({ context: { indexed_by: "closed" } }, "completed cards")
    assert_command({ context: { indexed_by: "closed" } }, "completed")

    assert_command({ context: { indexed_by: "newest" } }, "recent cards")
    assert_command({ context: { indexed_by: "latest" } }, "cards with recent activity")

    assert_command({ context: { indexed_by: "stalled" } }, "stalled cards")
    assert_command({ context: { indexed_by: "stalled" } }, "stagnated cards")
  end

  test "filter by card id" do
    # List context
    assert_command({ context: { card_ids: [ 123 ] } }, "card 123")
    assert_command({ context: { card_ids: [ 123, 456 ] } }, "card 123, 456")
    assert_command({ context: { terms: [ "123" ] } }, "123") # Notice existing cards will be intercepted earlier
  end

  test "filter by collections" do
    assert_command({ context: { collection_ids: [ "writebook" ] } }, "writebook collection")
  end

  test "close cards" do
    # List context
    assert_command({ commands: [ "/close" ] }, "close")
    assert_command({ commands: [ "/close not now" ] }, "close as not now")
    assert_command({ context: { assignee_ids: [ "jz" ] }, commands: [ "/close" ] }, "close cards assigned to jz")

    # Card context
    assert_command({ commands: [ "/close" ] }, "close", context: :card)
  end

  test "assign cards" do
    # List context
    assert_command({ commands: [ "/assign jz" ] }, "assign to jz")
    assert_command({ context: { tag_ids: [ "design" ] }, commands: [ "/assign jz" ] }, "assign cards agged with #design to jz", context: :card)
  end

  test "tag cards" do
    # List context
    assert_command({ commands: [ "/tag #design" ] }, "tag with #design")
  end

  test "move cards between considering and doing" do
    assert_command({ commands: [ "/consider" ] }, "consider")
    assert_command({ commands: [ "/consider" ] }, "move to consider")

    assert_command({ commands: [ "/do" ] }, "doing")
    assert_command({ commands: [ "/do" ] }, "move to doing")
  end

  test "combine commands and filters" do
    assert_command({ context: { assignee_ids: [ "jz" ], tag_ids: [ "design" ] }, commands: [ "/assign andy", "/tag #v2" ] }, "assign andy to the current #design cards assigned to jz and tag them with #v2")
    assert_command({ context: { assignee_ids: [ "andy" ] }, commands: [ "/close", "/assign kevin" ] }, "close cards assigned to andy and assign them to kevin")
    assert_command({ context: { tag_ids: [ "design" ], assignee_ids: [ "jz" ] }, commands: [ "/assign andy", "/tag #v2" ] },  "assign cards tagged with #design assigned to jz to andy and tag them with #v2")
  end

  private
    def assert_command(expected, query, context: :list)
      assert_equal expected, translate(query, context:)
    end

    def translate(query, user: @user, context: :list)
      raise "Context must be :card or _list" unless context.in?(%i[ card list ])
      url = context == :card ? card_url(cards(:logo)) : cards_url
      context = Command::Parser::Context.new(user, url: url)
      translator = Command::Ai::Translator.new(context)
      translator.translate(query)
    end
end
