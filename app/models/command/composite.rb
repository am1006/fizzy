# A composite of commands
class Command::Composite < Command
  store_accessor :data, :title

  has_many :commands, inverse_of: :parent, dependent: :destroy

  def execute
    ApplicationRecord.transaction do
      commands.collect { it.execute }
    end
  end

  def undo
    ApplicationRecord.transaction do
      undoable_commands.reverse.each(&:undo)
    end
  end

  def undoable?
    undoable_commands.any?
  end

  def confirmation_prompt
    confirmations = commands_excluding_redirections.collect(&:confirmation_prompt).collect { "- #{it}" }.join("\n")

    <<~MD
      This will:

      #{confirmations}
    MD
  end

  def needs_confirmation?
    commands.any?(&:needs_confirmation?)
  end

  private
    def commands_excluding_redirections
      commands.reject { it.is_a?(Command::VisitUrl) }
    end

    def undoable_commands
      @undoable_commands ||= commands.filter(&:undoable?)
    end
end
