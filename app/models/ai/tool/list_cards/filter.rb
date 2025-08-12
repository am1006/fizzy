class Ai::Tool::ListCards::Filter
  FILTERS = {
    ids: :apply_ids_filter,
    collection_ids: :apply_collection_ids_filter,
    golden: :apply_golden_filter,
    created_before: :apply_created_before_filter,
    created_after: :apply_created_after_filter,
    last_active_before: :apply_last_active_before_filter,
    last_active_after: :apply_last_active_after_filter
  }.freeze

  attr_reader :scope, :filters

  def initialize(scope:, filters:)
    @scope = scope
    @filters = filters
  end

  def filter
    FILTERS.reduce(scope) do |filtered_scope, (filter_name, method_name)|
      if filters[filter_name].present?
        send(method_name, filtered_scope)
      else
        filtered_scope
      end
    end
  end

  private
    def apply_ids_filter(scope)
      scope.where(id: filters[:ids])
    end

    def apply_collection_ids_filter(scope)
      scope.where(collection_id: filters[:collection_ids])
    end

    def apply_golden_filter(scope)
      scope.golden
    end

    def apply_created_before_filter(scope)
      scope.where(created_at: ...filters[:created_before])
    end

    def apply_created_after_filter(scope)
      scope.where(created_at: filters[:created_after]...)
    end

    def apply_last_active_before_filter(scope)
      scope.where(last_active_at: ...filters[:last_active_before])
    end

    def apply_last_active_after_filter(scope)
      scope.where(last_active_at: filters[:last_active_after]...)
    end
end
