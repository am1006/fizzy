require "test_helper"

class Collection::CardsTest < ActiveSupport::TestCase
  test "touch cards when the name changes" do
    collection = collections(:writebook)

    assert_enqueued_with(job: Card::TouchAllJob) do
      collection.update!(name: "New Name")
    end

    assert_no_enqueued_jobs(only: Card::TouchAllJob) do
      collection.update!(updated_at: 1.hour.from_now)
    end
  end
end
