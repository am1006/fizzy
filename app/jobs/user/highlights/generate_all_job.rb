class User::Highlights::GenerateAllJob < ApplicationJob
  queue_as :backend

  def perform
    ApplicationRecord.with_each_tenant do |tenant|
      User.generate_all_weekly_highlights
    end
  end
end
