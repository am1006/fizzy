class Column < ApplicationRecord
  include Positioned

  belongs_to :collection, touch: true
  has_many :cards, dependent: :nullify

  validates :name, presence: true
  validates :color, presence: true

  before_validation :set_default_color
  after_save_commit :touch_all_cards_later, if: :should_invalidate_cards?
  after_destroy_commit :touch_all_collection_cards

  private
    def set_default_color
      self.color ||= Card::DEFAULT_COLOR
    end

    def touch_all_cards_later
      Card::TouchAllJob.perform_later(self)
    end

    def should_invalidate_cards?
      saved_change_to_name? || saved_change_to_color?
    end

    def touch_all_collection_cards
      Card::TouchAllJob.perform_later(collection)
    end
end
