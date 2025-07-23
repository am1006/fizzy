require "test_helper"

class Events::ActivitySummariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
  end

  test "create" do
    assert_difference -> { Event::ActivitySummary.count }, +1 do
      perform_enqueued_jobs only: User::DayTimeline::SummarizeJob do
        post events_activity_summaries_path(day: Date.current)
      end
    end
  end
end
