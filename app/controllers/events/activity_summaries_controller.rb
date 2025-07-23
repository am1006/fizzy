class Events::ActivitySummariesController < ApplicationController
  include DayTimelinesScoped

  def create
    @day_timeline.summarize_later
  end
end
