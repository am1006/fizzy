class Ai::Tool < RubyLLM::Tool
  include Rails.application.routes.url_helpers

  private
    def paginated_response(records, page:, ordered_by:, per_page: nil, &block)
      page = GearedPagination::Recordset.new(records, ordered_by: ordered_by, per_page: per_page).page(page)

      response = [ "There are #{page.recordset.records_count} records in total." ]

      if page.only? || page.last?
        response << "This is the last page of results."
      else
        response << "This is one page of results."
        response << "To see more, use this cursor for the next page:"
        response << page.next_param
      end

      response << "Records:"
      response << "```"
      response << page.records.map(&block).to_json
      response << "```"

      response.join("\n")
    end

    def default_url_options
      Rails.application.default_url_options
        .reverse_merge(host: "fizzy.localhost", port: 3006)
        .merge(script_name: "/#{ApplicationRecord.current_tenant}")
    end
end
