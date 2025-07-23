class RemoveDataAndRenameColumnInEventActivitySummaries < ActiveRecord::Migration[8.1]
  def change
    remove_column :event_activity_summaries, :data, :jsonb
    rename_column :event_activity_summaries, :contents, :content
  end
end
