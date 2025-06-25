class Command::Ai::Parser
  include Rails.application.routes.url_helpers

  attr_reader :context

  delegate :user, to: :context

  def initialize(context)
    @context = context
  end

  def parse(query)
    normalized_query = resolve_named_params_to_ids command_translator.translate(query)
    build_composite_command_for normalized_query, query
  end

  private
    def command_translator
      Command::Ai::Translator.new(context)
    end

    def build_composite_command_for(normalized_query, query)
      query_context = context_from_query(normalized_query)
      resolved_context = query_context || context

      commands = Array.wrap(commands_from_query(normalized_query, resolved_context))

      if query_context
        commands.unshift Command::VisitUrl.new(user: user, url: query_context.url, context: resolved_context)
      end

      Command::Composite.new(title: query, commands: commands, user: user, line: query, context: resolved_context)
    end

    def commands_from_query(normalized_query, context)
      parser = Command::Parser.new(context)
      if command_lines = normalized_query[:commands].presence
        command_lines.collect { parser.parse(it) }
      end
    end

    def resolve_named_params_to_ids(normalized_query)
      normalized_query.tap do |query_json|
        if query_context = query_json[:context].presence
          query_context[:assignee_ids] = query_context[:assignee_ids]&.filter_map { |name| assignee_from(name)&.id }
          query_context[:creator_id] = assignee_from(query_context[:creator_id])&.id if query_context[:creator_id]
          query_context[:collection_ids] = query_context[:collection_ids]&.filter_map { |name| Collection.where("lower(name) like ?", "%#{name.downcase}%").first&.id }
          query_context[:tag_ids] = query_context[:tag_ids]&.filter_map { |name| ::Tag.find_by_title(name)&.id }
          query_context.compact!
        end
      end
    end

    def assignee_from(string)
      string_without_at = string.delete_prefix("@")
      User.all.find { |user| user.mentionable_handles.include?(string_without_at) }
    end

    def context_from_query(query_json)
      if context_properties = query_json[:context].presence
        url = cards_path(**context_properties)
        Command::Parser::Context.new(user, url: url)
      end
    end
end
