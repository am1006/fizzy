require "test_helper"

class CommentTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
  end

  test "searchable by body" do
    comment = cards(:logo).comments.create!(body: "I'd prefer something more rustic")

    skip("TODO:PLANB: search")
    assert_includes Comment.search("something rustic"), comment
  end
end
