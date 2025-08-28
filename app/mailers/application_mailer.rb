class ApplicationMailer < ActionMailer::Base
  default from: "The Fizzy team <support@37signals.com>"

  layout "mailer"
  append_view_path Rails.root.join("app/views/mailers")
  helper AvatarsHelper, HtmlHelper

  private
    def default_url_options
      super.merge(script_name: "/#{ApplicationRecord.current_tenant}")
    end
end
