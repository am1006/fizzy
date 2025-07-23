require "zlib"

module AiHelper
  LLM_MODELS = %w[
    chatgpt-4o-latest
    gpt-4.1
    gpt-3.5-turbo
    gpt-4.1-mini
    gpt-4.1-nano
    gpt-4o-mini
  ]

  def llm_model_options
    LLM_MODELS.map { |model| [ model, model ] }
  end
end
