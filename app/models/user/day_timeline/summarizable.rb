module User::DayTimeline::Summarizable
  extend ActiveSupport::Concern

  def summarized?
    summary.present?
  end

  def summary
    @summary ||= Event::ActivitySummary.for(events)
  end

  def summarizable?
    !day.today? || events.count >= 10
  end

  def summarize
    Event::ActivitySummary.create_for(events)
  end

  def summary_key
    Event::ActivitySummary.key_for(events)
  end

  def summarizable_content
    Event::Summarizer.new(events).summarizable_content
  end

  def summarize_later
    User::DayTimeline::SummarizeJob.perform_later(self)
  end
end
