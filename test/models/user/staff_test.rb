require "test_helper"

class User::StaffTest < ActiveSupport::TestCase
  test "only 37s email addresses are considered staff" do
    assert users(:kevin).staff?
    users(:kevin).email_address = "kevin@hey.com"

    assert_not users(:kevin).staff?
  end
end
