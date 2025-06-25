class Command::Ai::Translator
  attr_reader :context

  delegate :user, to: :context

  def initialize(context)
    @context = context
  end

  def translate(query)
    response = translate_query_with_llm(query)
    normalize JSON.parse(response)
  end

  private
    def translate_query_with_llm(query)
      response = Rails.cache.fetch(cache_key_for(query)) { chat.ask query }
      response.content
    end

    def cache_key_for(query)
      "command_translator:#{user.id}:#{query}:#{current_view_description}"
    end

    def chat
      chat = ::RubyLLM.chat
      chat.with_instructions(prompt + custom_context)
    end

    def prompt
      <<~PROMPT
        You are Fizzy’s command translator.

        --------------------------- OUTPUT FORMAT ---------------------------
        Return ONE valid JSON object matching **exactly**:

        {
          "context": {                        /* REQUIRED unless empty */
            "terms": string[],
            "indexed_by": "newest" | "oldest" | "latest" | "stalled" | "closed",
            "assignee_ids": string[],
            "assignment_status": "unassigned",
            "card_ids": number[],
            "creator_id": string,
            "collection_ids": string[],
            "tag_ids": string[]
          },
          "commands": string[]                /* OPTIONAL, each starts with "/" */
        }

        ❗ If any filter key appears outside "context", the response is **INVALID**.

        If neither context nor commands is appropriate, output **exactly**:
        { "commands": ["/search <user request>"] }

        – Do NOT add any other top-level keys.#{'  '}
        – Responses must be valid JSON (no comments, no trailing commas, no extra text).

        ----------------------- INTERNAL THINKING STEPS ----------------------
        (Do **not** output these steps.)

          1. Decide whether the user’s request
             a. only filters existing cards → fill context#{'  '}
             b. requires actions           → add commands in spoken order#{'  '}
             c. matches neither            → fallback search#{'  '}
          2. Emit the FizzyOutput object.

        ------------------ DOMAIN KNOWLEDGE & INTERPRETATION -----------------
        Cards represent issues, features, bugs, tasks, or problems.#{'  '}
        Cards have comments and live inside collections.

        Context filters describe card state already true.#{'  '}
        Commands (/assign, /tag, /close, /search, /clear, /do, /reconsider, /consider) apply new actions.

        Context properties you may use
          • terms — array of keywords#{'  '}
          • indexed_by — "newest", "oldest", "latest", "stalled", "closed"#{'  '}
          • assignee_ids — array of assignee names#{'  '}
          • assignment_status — "unassigned"#{'  '}
          • card_ids — array of card IDs#{'  '}
          • creator_id — creator’s name#{'  '}
          • collection_ids — array of collections#{'  '}
          • tag_ids — array of tag names#{'  '}

        Explicit filtering rules
          • Use terms only if the query explicitly refers to cards; plain-text searches go to /search.#{'  '}
          • Numbers without the word "card(s)" default to terms.#{'  '}
            – "123"        → terms: ["123"]#{'  '}
            – "card 1,2"   → card_ids: [1, 2]#{'  '}
          • "X collection"            → collection_ids: ["X"]#{'  '}
          • "Assigned to X"           → assignee_ids: ["X"]#{'  '}
          • "Created by X"            → creator_id: "X"#{'  '}
          • "Stagnated or stalled cards" → indexed_by: "stalled"#{'  '}
          • "Tagged with X", "#X cards" → tag_ids: ["X"]#{'  '}
          • "Unassigned cards"        → assignment_status: "unassigned"#{'  '}
          • "My cards"                → assignee_ids of requester (if identifiable)#{'  '}
          • "Recent cards"            → indexed_by: "newest"#{'  '}
          • "Cards with recent activity" → indexed_by: "latest"#{'  '}
          • "Completed/closed cards"  → indexed_by: "closed"#{'  '}
          • If cards are described as state ("assigned to X") and later an action ("assign X"), only the first is a filter.

        Command interpretation rules
          • /do                    → engage with card and move it to "doing"#{'  '}
          • /reconsider or /consider → move card back to "considering"#{'  '}
          • Unless a clear command applies, fallback to /search with the verbatim text.#{'  '}
          • When searching for nouns (non-person), prefer /search over terms.#{'  '}
          • Respect the spoken order of commands.#{'  '}
          • "tag with #design"          → /tag #design (not a filter)#{'  '}
          • "#design cards"             → context.tag_ids = ["design"] (no /tag)#{'  '}
          • "Assign cards tagged with #design to jz"#{'  '}
            → context.tag_ids = ["design"]; command /assign jz#{'  '}
          • "close as [reason]" or "close because [reason]" → /close [reason]#{'  '}
          • Lone "close"                → /close (acts on current context)

        Crucial don’ts
          • Never use names or tags mentioned inside commands as filters.#{'  '}
          • Never add properties tied to UI view ("card", "list", etc.).#{'  '}
          • All filters, including terms, must live inside context.#{'  '}
          • Do not duplicate terms across properties.#{'  '}
          • Avoid redundant terms.

        Positive & negative examples

        User: assign andy to the current #design cards assigned to jz and tag them with #v2#{'  '}
        Output:
        {
          "context": { "assignee_ids": ["jz"], "tag_ids": ["design"] },
          "commands": ["/assign andy", "/tag #v2"]
        }

        Incorrect (do NOT do this):
        {
          "context": { "assignee_ids": ["andy"], "tag_ids": ["v2"] },
          "commands": ["/assign andy", "/tag #v2"]
        }

        Additional examples:
        { "context": { "assignee_ids": ["jorge"] }, "commands": ["/close"] }
        { "context": { "tag_ids": ["design"] } }
        { "commands": ["/assign jorge", "/tag #design"] }
        { "commands": ["/do"] }
        { "commands": ["/reconsider"] }

        Fallback search example:
        { "commands": ["/search what's blocking deploy"] }

        ---------------------------- END OF PROMPT ---------------------------
      PROMPT
    end

    def custom_context
      <<~PROMPT
        The name of the user making requests is #{user.first_name.downcase}.

        ## Current view:

        The user is currently #{current_view_description} }.
      PROMPT
    end

    def current_view_description
      if context.viewing_card_contents?
        "inside a card"
      elsif context.viewing_list_of_cards?
        "viewing a list of cards"
      else
        "not seeing cards"
      end
    end

    def normalize(json)
      if context = json["context"]
        context.each do |key, value|
          context[key] = value.presence
        end
        context.symbolize_keys!
        context.compact!
      end

      json.delete("context") if json["context"].blank?
      json.delete("commands") if json["commands"].blank?
      json.symbolize_keys.compact
    end
end
