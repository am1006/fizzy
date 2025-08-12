class Ai::Tool::ListComments < Ai::Tool
  description <<-MD
    Lists all comments accessible by the current user.
    The response is paginated so you may need to iterate through multiple pages to get the full list.
    Responses are JSON objects that look like this:
    ```
    {
      "comments": [
        {
          "id": 3,
          "card_id": 5,
          "body": "This is a comment",
          "created_at": "2023-10-01T12:00:00Z",
          "creator": { "id": 1, "name": "John Doe" },
          "reactions": [
            { "content": "👍", "reacter": { "id": 2, "name": "Jane Doe" } }
          ]
      ],
      "pagination": {
        "next_page": "e3c2gh75e4..."
      }
    }
    ```
    Each comment object has the following fields:
    - id [Integer, not null]
    - card_id [Integer, not null]
    - body [String, not null]
    - created_at [String, not null] ISO8601 formatted timestamp
    - creator [Object, not null] the User that created the comment
    - system [Boolean, not null] indicates if the comment was created by the system
    - reactions [Array]
      - content [String, not null]
      - reacter [Object] represents a User
        - id [Integer, not null]
        - name [String, not null]
  MD

  param :page,
    type: :string,
    desc: "Which page to return. Leave balnk to get the first page",
    required: false
  param :query,
    type: :string,
    desc: "If provided, will perform a semantinc search by embeddings and return only matching comments",
    required: false
  param :card_id,
    type: :integer,
    desc: "If provided, will return only status changes for the specified card",
    required: false
  param :type,
    type: :string,
    desc: "If provided, returns either 'user' or 'system' comments, if ommited it returns both",
    required: false
  param :created_at_gte,
    type: :string,
    desc: "If provided, will return only comments created on or after after the given ISO timestamp",
    required: false
  param :created_at_lte,
    type: :string,
    desc: "If provided, will return only comments created on or before the given ISO timestamp",
    required: false

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def execute(**params)
    cards = Card.where(collection: user.collections)
    scope = Comment.where(card: cards).with_rich_text_description.includes(:card, :creator, reactions: [ :reacter ])

    scope = scope.search(params[:query]) if params[:query].present?
    scope = scope.where(card_id: params[:card_id].to_i) if params[:card_id].present?

    if params[:type]&.casecmp?("system")
      scope = scope.where(creator: { role: "system" })
    elsif params[:type]&.casecmp?("user")
      scope = scope.where.not(creator: { role: "system" })
    end

    if params[:created_at_gte].present?
      timestamp = Time.iso8601(params[:created_at_gte])
      scope = scope.where(created_at: timestamp..)
    end

    if params[:created_at_lte].present?
      timestamp = Time.iso8601(params[:created_at_lte])
      scope = scope.where(created_at: ..timestamp)
    end

    page = GearedPagination::Recordset.new(
      scope,
      ordered_by: { created_at: :asc, id: :desc }
    ).page(params[:page])

    {
      comments: page.records.map do |comment|
        {
          id: comment.id,
          card_id: comment.card_id,
          body: comment.body.to_plain_text,
          created_at: comment.created_at.iso8601,
          creator: comment.creator.as_json(only: [ :id, :name ]),
          system: comment.creator.system?,
          reactions: comment.reactions.map do |reaction|
            {
              content: reaction.content,
              reacter: reaction.reacter.as_json(only: [ :id, :name ])
            }
          end,
          url: collection_card_url(comment.card.collection_id, comment.card, anchor: "comment_#{comment.id}")
        }
      end,
      pagination: {
        next_page: page.next_param
      }
    }.to_json
  end
end
