# Extending Ruby and Rails Classes

This guide explains how Fizzy safely extends Ruby core classes and Rails framework components. The patterns here follow 37signals' principles of pragmatic, maintainable monkey patching that respects the host framework while adding necessary functionality.

## Table of Contents

1. [Philosophy](#philosophy)
2. [File Organization](#file-organization)
3. [Extension Patterns](#extension-patterns)
4. [When to Use Each Pattern](#when-to-use-each-pattern)
5. [Timing and Loading](#timing-and-loading)
6. [Real-World Examples](#real-world-examples)
7. [Testing Extensions](#testing-extensions)
8. [Anti-Patterns to Avoid](#anti-patterns-to-avoid)

---

## Philosophy

37signals' approach to extending Ruby and Rails follows these principles:

1. **Prefer composition over modification** - Use concerns, modules, and prepend rather than reopening classes directly
2. **Make extensions explicit and discoverable** - Centralize extensions in dedicated files with clear names
3. **Use Rails' loading hooks** - Let Rails tell you when classes are ready to extend
4. **Keep extensions minimal** - Only add what you genuinely need
5. **Document the "why"** - Extensions should have comments explaining their purpose, especially workarounds for bugs

The goal is to extend framework behavior without creating maintenance nightmares or breaking upgrades.

---

## File Organization

Fizzy organizes extensions in two primary locations:

### 1. `lib/rails_ext/` - Framework Extensions

This directory contains modules that extend Rails framework classes. Files are named after what they extend:

```
lib/rails_ext/
  active_record_date_arithmetic.rb      # Database adapter extensions
  active_record_replica_support.rb      # Read replica helpers
  active_record_uuid_type.rb            # Custom UUID type
  active_storage_analyze_job_suppress_broadcasts.rb
  active_storage_blob_service_url_for_direct_upload_expiry.rb
  active_support_array_conversions.rb   # Array helper methods
  action_mailer_mail_delivery_job.rb    # Mailer job extensions
  prepend_order.rb                      # ActiveRecord::Relation extension
  string.rb                             # Ruby core class extension
```

These files are loaded via `config/initializers/extensions.rb`:

```ruby
# config/initializers/extensions.rb
Dir["#{Rails.root}/lib/rails_ext/*"].each { |path| require "rails_ext/#{File.basename(path)}" }
```

### 2. `config/initializers/` - Application-Specific Extensions

Initializers handle extensions that:

- Need Rails to be fully loaded
- Configure framework behavior
- Integrate with multi-tenancy

Key files:

- `active_job.rb` - Job tenant context preservation
- `uuid_primary_keys.rb` - UUID schema/type extensions
- `table_definition_column_limits.rb` - MySQL-compatible column limits
- `uuid_framework_models.rb` - Account associations on framework models
- `action_text.rb` - ActionText customizations
- `active_storage.rb` - ActiveStorage integrations
- `tenanting/turbo.rb` - Turbo Streams tenant awareness

---

## Extension Patterns

Fizzy uses several distinct patterns for extending classes, each suited to different situations:

### Pattern 1: Prepend with ActiveSupport::Concern

The **preferred pattern** for extending Rails classes. Uses `prepend` to insert your module at the front of the method lookup chain, allowing you to call `super` to invoke the original behavior.

```ruby
# config/initializers/active_job.rb

module FizzyActiveJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
    self.enqueue_after_transaction_commit = true
  end

  def initialize(...)
    super
    @account = Current.account
  end

  def serialize
    super.merge({ "account" => @account&.to_gid })
  end

  def deserialize(job_data)
    super
    if _account = job_data.fetch("account", nil)
      @account = GlobalID::Locator.locate(_account)
    end
  end

  def perform_now
    if account.present?
      Current.with_account(account) { super }
    else
      super
    end
  end
end

ActiveSupport.on_load(:active_job) do
  prepend FizzyActiveJobExtensions
end
```

**Why this works well:**

- `prepended do` block runs class-level configuration when the module is prepended
- Each method calls `super` to preserve original behavior
- `ActiveSupport.on_load` ensures the class exists before extending
- The module is self-contained and testable

### Pattern 2: Include with Concern for Additive Behavior

Use `include` when adding new methods without overriding existing ones:

```ruby
# lib/rails_ext/active_record_replica_support.rb

module ActiveRecordReplicaSupport
  extend ActiveSupport::Concern

  class_methods do
    def configure_replica_connections
      if replica_configured?
        connects_to database: { writing: :primary, reading: :replica }
      end
    end

    def replica_configured?
      configurations.find_db_config("replica").present?
    end

    def with_reading_role(&block)
      if replica_configured?
        connected_to(role: :reading, &block)
      else
        yield
      end
    end
  end
end

ActiveRecord::Base.include ActiveRecordReplicaSupport
```

**When to use:** Adding entirely new capabilities that don't conflict with existing methods.

### Pattern 3: Direct Include for Simple Extensions

For straightforward additions to Ruby core classes:

```ruby
# lib/rails_ext/active_support_array_conversions.rb

module ChoiceSentenceArrayConversion
  def to_choice_sentence
    to_sentence two_words_connector: " or ", last_word_connector: ", or "
  end
end

Array.include ChoiceSentenceArrayConversion
```

**When to use:** Adding utility methods to Ruby core classes.

### Pattern 4: Direct Class Extension

For minimal extensions to core Ruby classes:

```ruby
# lib/rails_ext/string.rb

class String
  def all_emoji?
    self.match?(/\A(\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)+\z/u)
  end
end
```

**When to use:** Small, isolated utility methods on Ruby core classes. Keep these rare and well-justified.

### Pattern 5: Database-Adapter-Specific Extensions

When behavior varies by database, create separate modules and apply them conditionally:

```ruby
# lib/rails_ext/active_record_date_arithmetic.rb

module MysqlDateArithmetic
  def date_subtract(date_column, seconds_expression)
    "DATE_SUB(#{date_column}, INTERVAL #{seconds_expression} SECOND)"
  end
end

module SqliteDateArithmetic
  def date_subtract(date_column, seconds_expression)
    "datetime(#{date_column}, '-' || (#{seconds_expression}) || ' seconds')"
  end
end

ActiveSupport.on_load(:active_record) do
  if defined?(ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter)
    ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(MysqlDateArithmetic)
  end

  if defined?(ActiveRecord::ConnectionAdapters::SQLite3Adapter)
    ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteDateArithmetic)
  end
end
```

**Why this pattern:** Provides a consistent API (`date_subtract`) while handling database-specific SQL generation.

### Pattern 6: to_prepare for Reloadable Extensions

Use `Rails.application.config.to_prepare` when extending application classes that may be reloaded in development:

```ruby
# config/initializers/uuid_framework_models.rb

Rails.application.config.to_prepare do
  ActionText::RichText.belongs_to :account, default: -> { record.account }
  ActiveStorage::Attachment.belongs_to :account, default: -> { record.account }
  ActiveStorage::Blob.belongs_to :account, default: -> { Current.account }
  ActiveStorage::VariantRecord.belongs_to :account, default: -> { blob.account }
end
```

**When to use:** Adding associations or callbacks to framework models that need to work with code reloading.

### Pattern 7: class_eval for Test-Only Modifications

Reserve `class_eval` for test environments where you need to modify behavior:

```ruby
# saas/lib/fizzy/saas/testing.rb

Queenbee::Remote::Account.class_eval do
  def next_id
    super + Random.rand(1000000)
  end
end
```

**When to use:** Test-specific overrides that shouldn't affect production.

---

## When to Use Each Pattern

| Situation                                 | Pattern                       | Example                   |
| ----------------------------------------- | ----------------------------- | ------------------------- |
| Override existing method, call original   | `prepend` with Concern        | Active Job tenant context |
| Add new methods to framework class        | `include` with Concern        | Replica support methods   |
| Add method to Ruby core class             | Direct extension or `include` | `String#all_emoji?`       |
| Database-specific behavior                | Conditional `prepend`         | Date arithmetic           |
| Extend framework models with associations | `to_prepare`                  | Account on ActiveStorage  |
| Test-only modifications                   | `class_eval`                  | Mock behavior             |
| Fix framework bugs                        | `prepend` with comment        | FTS5 schema dumper fix    |

---

## Timing and Loading

Rails provides several hooks for timing your extensions correctly:

### ActiveSupport.on_load

Use for framework classes that load lazily:

```ruby
# Waits until ActiveRecord is loaded
ActiveSupport.on_load(:active_record) do
  # Safe to extend ActiveRecord::Base here
end

# Common hooks:
# :active_record           - ActiveRecord::Base
# :active_job              - ActiveJob::Base
# :action_controller       - ActionController::Base
# :action_controller_base  - ActionController::Base specifically
# :active_storage_blob     - ActiveStorage::Blob
# :active_storage_attachment - ActiveStorage::Attachment
# :action_text_rich_text   - ActionText::RichText
# :active_record_trilogyadapter - Trilogy (MySQL) adapter
# :active_record_sqlite3adapter - SQLite3 adapter
```

### Database-Adapter-Specific Hooks

```ruby
# Only runs when the Trilogy adapter is loaded
ActiveSupport.on_load(:active_record_trilogyadapter) do
  ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(MysqlUuidAdapter)
end

# Only runs when SQLite3 adapter is loaded
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteUuidAdapter)
end
```

### config.after_initialize

For extensions that need Rails fully initialized:

```ruby
Rails.application.config.after_initialize do
  Turbo::StreamsChannel.prepend TurboStreamsJobExtensions
end
```

### config.to_prepare

For extensions to reloadable classes:

```ruby
Rails.application.config.to_prepare do
  ActionMailer::MailDeliveryJob.include SmtpDeliveryErrorHandling
end
```

---

## Real-World Examples

### Example 1: UUID Primary Keys

A comprehensive example showing multiple extension patterns working together:

```ruby
# config/initializers/uuid_primary_keys.rb

# Module for auto-generating UUID defaults
module UuidPrimaryKeyDefault
  def load_schema!
    define_uuid_primary_key_pending_default
    super
  end

  private
    def define_uuid_primary_key_pending_default
      if uuid_primary_key?
        pending_attribute_modifications << PendingUuidDefault.new(primary_key)
      end
    rescue ActiveRecord::StatementInvalid
      # Table doesn't exist yet
    end

    def uuid_primary_key?
      table_name && primary_key && schema_cache.columns_hash(table_name)[primary_key]&.type == :uuid
    end

    PendingUuidDefault = Struct.new(:name) do
      def apply_to(attribute_set)
        attribute_set[name] = attribute_set[name].with_user_default(-> { ActiveRecord::Type::Uuid.generate })
      end
    end
end

# MySQL-specific adapter extensions
module MysqlUuidAdapter
  extend ActiveSupport::Concern

  def lookup_cast_type(sql_type)
    if sql_type == "binary(16)"
      ActiveRecord::Type.lookup(:uuid, adapter: :trilogy)
    else
      super
    end
  end

  class_methods do
    def native_database_types
      @native_database_types_with_uuid ||= super.merge(uuid: { name: "binary", limit: 16 })
    end
  end
end

# Apply extensions at the right time
ActiveSupport.on_load(:active_record) do
  ActiveRecord::Base.singleton_class.prepend(UuidPrimaryKeyDefault)
  ActiveRecord::ConnectionAdapters::TableDefinition.prepend(TableDefinitionUuidSupport)
end

ActiveSupport.on_load(:active_record_trilogyadapter) do
  ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter.prepend(MysqlUuidAdapter)
end
```

### Example 2: Fixing Framework Bugs

When working around Rails bugs, document extensively:

```ruby
# lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb

# Avoid page refreshes from Active Storage analyzing blobs when these are attached.
#
# A better option would be to disable touching with +touch_attachment_records+ but
# there is currently a bug https://github.com/rails/rails/issues/55144
module ActiveStorageAnalyzeJobSuppressBroadcasts
  def perform(blob)
    Board.suppressing_turbo_broadcasts do
      Card.suppressing_turbo_broadcasts do
        super
      end
    end
  end
end

ActiveSupport.on_load :active_storage_blob do
  ActiveStorage::AnalyzeJob.prepend ActiveStorageAnalyzeJobSuppressBroadcasts
end
```

### Example 3: Changing Default Behavior

Override framework defaults with clear documentation:

```ruby
# lib/rails_ext/active_storage_blob_service_url_for_direct_upload_expiry.rb

#
#  see https://github.com/basecamp/haystack/pull/7862
#
module ActiveStorage
  mattr_accessor :service_urls_for_direct_uploads_expire_in, default: 48.hours
end

module ActiveStorageBlobServiceUrlForDirectUploadExpiry
  # Override default expires_in to accommodate long upload URL expiry
  # without having to lengthen download URL expiry.
  #
  # Accounts for Cloudflare only proxying slow client uploads once they're
  # fully buffered, long after the URL expired.
  #
  # 48 hours covers a 10GB upload at 0.5Mbps.
  def service_url_for_direct_upload(expires_in: ActiveStorage.service_urls_for_direct_uploads_expire_in)
    super
  end
end

ActiveSupport.on_load :active_storage_blob do
  prepend ::ActiveStorageBlobServiceUrlForDirectUploadExpiry
end
```

### Example 4: Multi-Tenant Turbo Streams

Ensuring Turbo broadcasts include correct URL prefixes:

```ruby
# config/initializers/tenanting/turbo.rb

module TurboStreamsJobExtensions
  extend ActiveSupport::Concern

  class_methods do
    def render_format(format, **rendering)
      if Current.account.present?
        ApplicationController.renderer.new(script_name: Current.account.slug).render(formats: [ format ], **rendering)
      else
        super
      end
    end
  end
end

Rails.application.config.after_initialize do
  Turbo::StreamsChannel.prepend TurboStreamsJobExtensions
end
```

---

## Testing Extensions

### Testing Prepended Behavior

```ruby
# test/lib/rails_ext/active_job_extensions_test.rb
require "test_helper"

class ActiveJobExtensionsTest < ActiveSupport::TestCase
  test "jobs capture account context on initialization" do
    with_account(accounts(:acme)) do
      job = TestJob.new
      assert_equal accounts(:acme), job.account
    end
  end

  test "jobs serialize and deserialize account" do
    with_account(accounts(:acme)) do
      job = TestJob.new
      serialized = job.serialize

      new_job = TestJob.new
      new_job.deserialize(serialized)

      assert_equal accounts(:acme), new_job.account
    end
  end

  test "jobs restore account context on perform" do
    captured_account = nil

    job_class = Class.new(ApplicationJob) do
      define_method(:perform) do
        captured_account = Current.account
      end
    end

    job = nil
    with_account(accounts(:acme)) do
      job = job_class.new
    end

    Current.without_account do
      job.perform_now
    end

    assert_equal accounts(:acme), captured_account
  end
end
```

### Testing Database-Specific Extensions

```ruby
# test/lib/rails_ext/date_arithmetic_test.rb
require "test_helper"

class DateArithmeticTest < ActiveSupport::TestCase
  test "date_subtract generates valid SQL for current adapter" do
    connection = ActiveRecord::Base.connection
    sql = connection.date_subtract("created_at", "3600")

    # Verify it generates valid SQL by using it in a query
    assert_nothing_raised do
      Card.where("#{sql} < ?", Time.current).to_a
    end
  end
end
```

---

## Anti-Patterns to Avoid

### 1. Reopening Classes Without Modules

**Bad:**

```ruby
class ActiveRecord::Base
  def my_method
    # ...
  end
end
```

**Good:**

```ruby
module MyExtension
  def my_method
    # ...
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::Base.include MyExtension
end
```

### 2. Overriding Without Calling Super

**Bad:**

```ruby
module BadExtension
  def serialize
    { "my_key" => "my_value" }  # Loses original data!
  end
end
```

**Good:**

```ruby
module GoodExtension
  def serialize
    super.merge("my_key" => "my_value")
  end
end
```

### 3. Extending Before Classes Exist

**Bad:**

```ruby
# In config/initializers/early.rb
ActiveStorage::Blob.prepend MyExtension  # May not be loaded yet!
```

**Good:**

```ruby
ActiveSupport.on_load(:active_storage_blob) do
  prepend MyExtension
end
```

### 4. Using alias_method_chain (Deprecated)

**Bad:**

```ruby
module OldStyle
  def self.included(base)
    base.alias_method_chain :method, :feature
  end

  def method_with_feature
    method_without_feature + extra
  end
end
```

**Good:**

```ruby
module ModernStyle
  def method
    super + extra
  end
end
SomeClass.prepend ModernStyle
```

### 5. Scattered Extensions

**Bad:**

```ruby
# Random extensions in various files throughout the app
# app/models/card.rb
class String
  def card_title_format
    # ...
  end
end
```

**Good:**

```ruby
# Centralized in lib/rails_ext/string.rb
class String
  def card_title_format
    # ...
  end
end
```

---

## Summary

Fizzy's approach to extending Ruby and Rails follows these key principles:

1. **Use `prepend` with `ActiveSupport::Concern`** for overriding behavior while preserving original functionality
2. **Use `ActiveSupport.on_load`** to time extensions correctly
3. **Centralize extensions** in `lib/rails_ext/` and load them from a single initializer
4. **Document the "why"** with comments, especially for bug workarounds
5. **Test extensions** to ensure they work across Rails upgrades
6. **Keep extensions minimal** - only add what you genuinely need

The goal is maintainable code that works with Rails rather than against it, making upgrades smoother and debugging easier.

---

## Related Files

Key files demonstrating these patterns:

- `/Users/leo/zDev/GitHub/fizzy/config/initializers/extensions.rb` - Extension loader
- `/Users/leo/zDev/GitHub/fizzy/config/initializers/active_job.rb` - Job tenant context
- `/Users/leo/zDev/GitHub/fizzy/config/initializers/uuid_primary_keys.rb` - UUID system
- `/Users/leo/zDev/GitHub/fizzy/lib/rails_ext/active_record_date_arithmetic.rb` - Database adapter extensions
- `/Users/leo/zDev/GitHub/fizzy/lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb` - Bug workaround
- `/Users/leo/zDev/GitHub/fizzy/config/initializers/tenanting/turbo.rb` - Turbo tenant awareness

---

Finally, not sure when to patch? Check out the [Gem Patching Timing](/docs/design/gem-patching-timing.md) guide.
