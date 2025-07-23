class User::DayTimeline
  include Serializable, Summarizable

  attr_reader :user, :day, :filter

  delegate :today?, to: :day

  def initialize(user, day, filter)
    @user, @day, @filter = user, day, filter
  end

  def has_activity?
    events.any?
  end

  def events
    filtered_events.where(created_at: window).order(created_at: :desc)
  end

  def next_day
    latest_event_before&.created_at
  end

  def earliest_time
    next_day&.tomorrow&.beginning_of_day
  end

  def latest_time
    day.yesterday.beginning_of_day
  end

  private
    def filtered_events
      @filtered_events ||= begin
        events = Event.where(collection: collections)
        events = events.where(creator_id: filter.creators.ids) if filter.creators.present?
        events
      end
    end

    def collections
      filter.collections.presence || user.collections
    end

    def latest_event_before
      filtered_events.where(created_at: ...day.beginning_of_day).chronologically.last
    end

    def window
      day.all_day
    end
end
