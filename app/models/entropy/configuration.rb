class Entropy::Configuration < ApplicationRecord
  belongs_to :container, polymorphic: true

  after_commit :touch_all_cards_later

  class << self
    def default
      Account.sole.default_entropy_configuration
    end
  end

  private
    def touch_all_cards_later
      Card::TouchAllJob.perform_later(container)
    end
end
