require "test_helper"

class Event::ActivitySummaryTest < ActiveSupport::TestCase
  include VcrTestHelper

  setup do
    @events = Event.limit(3)

    # Make sure we fix dates since they change the prompt and this gets VCR confused
    anchor_date = Time.zone.parse("2025-08-12 9am")
    [ Event, Card, Comment ].each do |klass|
      klass.update_all created_at: anchor_date
    end
  end

  test "create summaries only once for a given set of events" do
    summary = assert_difference -> { Event::ActivitySummary.count }, +1 do
      Event::ActivitySummary.create_for(@events)
    end

    assert_no_difference -> { Event::ActivitySummary.count } do
      assert_equal summary, Event::ActivitySummary.create_for(@events)
      assert_equal summary, Event::ActivitySummary.create_for(@events.order("action desc").where(id: @events.ids)) # order does not matter
    end
  end

  test "fetching a existing summary" do
    assert_nil Event::ActivitySummary.for(@events)

    summary = Event::ActivitySummary.create_for(@events)
    assert_equal summary, Event::ActivitySummary.for(@events)
  end

  test "getting an HTML summary for a set of events" do
    summary = Event::ActivitySummary.create_for(@events)
    assert_includes summary.to_html, "layout"
  end
end
