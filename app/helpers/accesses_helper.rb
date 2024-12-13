module AccessesHelper
  def access_toggles_for(users, selected:)
    render partial: "buckets/access_toggle",
      collection: users, as: :user,
      locals: { selected: selected },
      cached: ->(user) { [ user, selected ] }
  end
end
