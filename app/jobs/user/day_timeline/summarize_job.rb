class User::DayTimeline::SummarizeJob < ApplicationJob
  def perform(day_timeline)
    day_timeline.summarize
  end
end
