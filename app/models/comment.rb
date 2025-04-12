class Comment < ApplicationRecord
  include Messageable, Searchable

  belongs_to :creator, class_name: "User", default: -> { Current.user }
  has_many :reactions, dependent: :delete_all

  has_markdown :body
  searchable_by :body_plain_text, using: :comments_search_index, as: :body

  # FIXME: Not a fan of this. Think all references to comment should come directly from the message.
  scope :belonging_to_card, ->(card) { joins(:message).where(messages: { card_id: card.id }) }

  after_create_commit :watch_card_by_creator, :track_commented_card
  after_destroy_commit :cleanup_events

  def to_partial_path
    "cards/#{super}"
  end

  private
    def watch_card_by_creator
      card.watch_by creator
    end

    def track_commented_card
      card.track_event :commented, comment_id: id
    end

    # FIXME: This isn't right. We need to introduce an eventable polymorphic association for this.
    def cleanup_events
      # Delete events that reference directly in particulars
      Event.where(particulars: { comment_id: id }).destroy_all
    end
end
