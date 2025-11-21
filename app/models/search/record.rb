class Search::Record < ApplicationRecord
  include const_get(connection.adapter_name)

  belongs_to :searchable, polymorphic: true
  belongs_to :card

  validates :account_id, :searchable_type, :searchable_id, :card_id, :board_id, :created_at, presence: true

  scope :for_query, ->(query:, user:) do
    if query.valid? && user.board_ids.any?
      matching(query.to_s, user.account_id).where(account_id: user.account_id, board_id: user.board_ids)
    else
      none
    end
  end

  scope :search, ->(query:, user:) do
    for_query(query: query, user: user)
      .includes(:searchable, card: [ :board, :creator ])
      .order(created_at: :desc)
      .select(:id, :account_id, :searchable_type, :searchable_id, :card_id, :board_id, :title, :content, :created_at, *search_fields(query))
  end

  def source
    searchable_type == "Comment" ? searchable : card
  end

  def comment
    searchable if searchable_type == "Comment"
  end
end
