require "test_helper"

class ColumnTest < ActiveSupport::TestCase
  test "creates column with default color when color not provided" do
    column = collections(:writebook).columns.create!(name: "New Column")

    assert_equal Card::DEFAULT_COLOR, column.color
  end

  test "touch all the cards when the name or color changes" do
    column = columns(:writebook_triage)

    assert_enqueued_with(job: Card::TouchAllJob) do
      column.update!(name: "New Name")
    end

    assert_enqueued_with(job: Card::TouchAllJob) do
      column.update!(color: "#FF0000")
    end

    assert_no_enqueued_jobs(only: Card::TouchAllJob) do
      column.update!(updated_at: 1.hour.from_now)
    end
  end

  test "touch all collection cards when column is destroyed" do
    column = columns(:writebook_triage)

    assert_enqueued_with(job: Card::TouchAllJob, args: [ column.collection ]) do
      column.destroy
    end
  end
end
