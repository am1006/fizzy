module Collection::Cards
  extend ActiveSupport::Concern

  included do
    has_many :cards, dependent: :destroy

    after_update_commit :touch_all_cards_later, if: :saved_change_to_name?
  end

  private
    def touch_all_cards_later
      Card::TouchAllJob.perform_later(self)
    end
end
