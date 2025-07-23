module User::Staff
  extend ActiveSupport::Concern

  included do
    has_one :debug_prompt, dependent: :destroy
  end

  def staff?
    email_address.ends_with?("@37signals.com")
  end
end
