# Gem Patching Timing: Understanding the Rails Boot Sequence

This guide explains how to determine **where** to place a gem patch based on **when** an error occurs during the Rails boot process. Understanding the boot sequence is essential for fixing gem compatibility issues, especially those that crash during startup.

## Table of Contents

1. [The Rails Boot Sequence](#the-rails-boot-sequence)
2. [Reading Stack Traces for Timing](#reading-stack-traces-for-timing)
3. [Decision Tree: Where to Place Patches](#decision-tree-where-to-place-patches)
4. [Case Study: phlex-rails Boot Crash](#case-study-phlex-rails-boot-crash)
5. [Patch Placement Options](#patch-placement-options)
6. [Examples from Fizzy](#examples-from-fizzy)
7. [Debugging Boot Issues](#debugging-boot-issues)

---

## The Rails Boot Sequence

Understanding when code executes is crucial for patching. Here is the complete Rails boot sequence with timing annotations:

```
PHASE 1: RUBY BOOTSTRAP (config/boot.rb)
========================================
1. Set BUNDLE_GEMFILE path
2. require "bundler/setup"         <- Bundler resolves gems, loads gemspec files
3. require "bootsnap/setup"        <- Optional: Sets up caching

PHASE 2: FRAMEWORK LOADING (config/application.rb)
==================================================
4. require_relative "boot"         <- Runs Phase 1
5. require "rails/all"             <- Loads Rails framework classes
6. require any pre-Bundler libs    <- Custom early-load code (rare)
7. Bundler.require(*Rails.groups)  <- LOADS ALL GEM CODE FROM GEMFILE
   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   THIS IS WHERE MOST GEM CRASHES HAPPEN

8. class Application < Rails::Application  <- Define your app class
     config.load_defaults 8.1
   end

PHASE 3: ENVIRONMENT INITIALIZATION (config/environment.rb)
===========================================================
9. require_relative "application"  <- Runs Phase 2
10. Rails.application.initialize!  <- THE BIG MOMENT
    |
    +-- Run before_configuration callbacks
    +-- Load config/environments/#{RAILS_ENV}.rb
    +-- Run before_initialize callbacks
    +-- Run Railtie initializers (alphabetically by gem)
    +-- Run config/initializers/*.rb (alphabetically)
    +-- Run after_initialize callbacks
    +-- Eager load code (production) or setup autoloading (development)

PHASE 4: APPLICATION READY
==========================
11. Application is fully initialized
12. Server starts accepting requests (or rake task runs, etc.)
```

### Key Insight: Bundler.require Is the Danger Zone

When `Bundler.require` runs, it loads every gem listed in your Gemfile (for the current group). This means:

1. Each gem's main file is `require`d
2. That file typically `require`s other files in the gem
3. All top-level code in those files **executes immediately**
4. `include`, `extend`, and `included` blocks all run during this phase

**Initializers run AFTER Bundler.require.** If a gem crashes during `Bundler.require`, no initializer code will ever execute.

---

## Reading Stack Traces for Timing

Stack traces tell you exactly when an error occurred. Learning to read them reveals where your patch must go.

### Anatomy of a Boot-Time Stack Trace

```ruby
NoMethodError: undefined method `class_attribute' for module Phlex::Rails::Streaming
  from /gems/phlex-rails-2.3.1/lib/phlex/rails/streaming.rb:5:in `<module:Streaming>'
  from /gems/phlex-rails-2.3.1/lib/phlex/rails/streaming.rb:3:in `<module:Rails>'
  from /gems/phlex-rails-2.3.1/lib/phlex/rails/streaming.rb:2:in `<module:Phlex>'
  from /gems/phlex-rails-2.3.1/lib/phlex/rails/streaming.rb:1:in `<main>'
  from /gems/phlex-rails-2.3.1/lib/phlex-rails.rb:12:in `require'
  from /gems/phlex-rails-2.3.1/lib/phlex-rails.rb:12:in `<main>'
  from /gems/bundler-2.5.6/lib/bundler/runtime.rb:123:in `require'
  from /gems/bundler-2.5.6/lib/bundler/runtime.rb:123:in `block in require'
  from /gems/bundler-2.5.6/lib/bundler/runtime.rb:108:in `each'
  from /gems/bundler-2.5.6/lib/bundler/runtime.rb:108:in `require'
  from /gems/bundler-2.5.6/lib/bundler.rb:201:in `require'
  from config/application.rb:5:in `<main>'
```

### Reading the Stack (Bottom to Top)

| Stack Frame                              | What It Tells You                            |
| ---------------------------------------- | -------------------------------------------- |
| `config/application.rb:5:in '<main>'`    | Error during app loading                     |
| `bundler/runtime.rb ... require`         | Bundler is requiring gems                    |
| `phlex-rails.rb:12:in '<main>'`          | The gem's main file is being loaded          |
| `streaming.rb:1:in '<main>'`             | A sub-file is being loaded                   |
| `streaming.rb:5:in '<module:Streaming>'` | **Crash location**: inside module definition |

### Key Indicators in Stack Traces

| Pattern                        | Meaning                  | Patch Location             |
| ------------------------------ | ------------------------ | -------------------------- |
| `bundler/runtime.rb` in stack  | During Bundler.require   | **Before** Bundler.require |
| `<main>` frames from gem files | Top-level code executing | **Before** Bundler.require |
| `initializers/*.rb` in stack   | During initializer phase | Can use initializers       |
| `after_initialize` in stack    | After app initialized    | Can use `after_initialize` |
| `to_prepare` in stack          | During autoload/reload   | Can use `to_prepare`       |
| `on_load` callback in stack    | During lazy loading      | Can use `on_load`          |

### Quick Timing Test

Not sure when your code runs? Add this debugging line:

```ruby
puts "=== MY CODE RUNNING: Bundler loaded? #{defined?(Bundler) ? 'yes' : 'no'}, Rails loaded? #{defined?(Rails) ? 'yes' : 'no'}, Rails initialized? #{Rails.application&.initialized? rescue 'no'}"
```

---

## Decision Tree: Where to Place Patches

```
START: Where does the error occur?
         |
         v
+-------------------+
| Check stack trace |
+-------------------+
         |
         v
Does stack include "bundler/runtime.rb"
or show gem files with '<main>'?
         |
    +----+----+
    |         |
   YES        NO
    |         |
    v         v
+-------------+    +------------------+
| BEFORE      |    | Does stack show  |
| Bundler.    |    | initializer file?|
| require     |    +------------------+
+-------------+           |
    |              +------+------+
    v              |             |
Place patch       YES            NO
in config/        |             |
application.rb    v             v
BEFORE line:    Use an       Check for
Bundler.require initializer  on_load or
                            after_initialize
```

### Patch Location Summary

| Error Timing               | Where to Put Patch           | File Location                             |
| -------------------------- | ---------------------------- | ----------------------------------------- |
| During Bundler.require     | Before `Bundler.require`     | `config/application.rb` (before line 5-7) |
| During require "rails/all" | Before `require "rails/all"` | `config/application.rb` (before line 2)   |
| During initializers        | In an initializer            | `config/initializers/`                    |
| During lazy loading        | In `on_load` block           | `config/initializers/`                    |
| After initialization       | In `after_initialize`        | `config/initializers/`                    |
| On code reload             | In `to_prepare`              | `config/initializers/`                    |

---

## Case Study: phlex-rails Boot Crash

This real-world example demonstrates the complete debugging and patching process.

### The Error

```ruby
NoMethodError: undefined method `class_attribute' for module Phlex::Rails::Streaming
```

### The Problematic Code

```ruby
# In phlex-rails gem: lib/phlex/rails/streaming.rb
module Phlex::Rails::Streaming
  include ActionController::Live  # <- This line triggers the error
end
```

### Why It Fails

1. `ActionController::Live` has an `included` block:

   ```ruby
   module ActionController::Live
     extend ActiveSupport::Concern

     included do
       class_attribute :perform_caching  # Expects a Class, not Module!
     end
   end
   ```

2. When you `include ActionController::Live` in a **module** (not a class), the `included` block runs
3. `class_attribute` is a method that only works on Classes
4. Plain modules don't have `class_attribute`
5. The gem crashes at load time

### Analyzing the Stack Trace

```ruby
from /gems/bundler-2.5.6/lib/bundler/runtime.rb:123:in `require'
from config/application.rb:5:in `<main>'
```

**Key observation**: The error happens during `Bundler.require` (line 5 of application.rb). Initializers have not run yet.

### Why Initializers Won't Work

```ruby
# config/initializers/phlex_rails_fix.rb
# THIS WILL NEVER RUN - the app crashes before initializers load!

module Phlex::Rails::Streaming
  extend ActiveSupport::Concern
end
```

### The Solution: Pre-Define the Module

Place the fix **before** `Bundler.require` in `config/application.rb`:

```ruby
# config/application.rb
require_relative "boot"
require "rails/all"

# FIX: Pre-define Phlex::Rails::Streaming with ActiveSupport::Concern
# This must happen BEFORE Bundler.require loads phlex-rails
# See: https://github.com/yippee-fun/phlex-rails/issues/323
module Phlex
  module Rails
    module Streaming
      extend ActiveSupport::Concern
    end
  end
end

Bundler.require(*Rails.groups)  # Now when phlex-rails loads, it reopens our module

module Fizzy
  class Application < Rails::Application
    # ...
  end
end
```

### How the Fix Works

1. Ruby evaluates `module Phlex::Rails::Streaming` in our patch
2. This creates the module and extends it with `ActiveSupport::Concern`
3. When `Bundler.require` loads phlex-rails, Ruby **reopens** the existing module
4. The `include ActionController::Live` line runs
5. `ActionController::Live`'s `included` block runs
6. Because `Phlex::Rails::Streaming` now has `ActiveSupport::Concern`, the concern chain works:
   - Concern knows how to defer `included` blocks
   - When eventually included in a Class, it will work correctly

---

## Patch Placement Options

### Option 1: Before Bundler.require (config/application.rb)

**Use when**: Gem crashes during initial require

```ruby
# config/application.rb
require_relative "boot"
require "rails/all"

# Pre-Bundler patches go here
module SomeGem
  module Problematic
    # Fix the issue before the gem loads
  end
end

Bundler.require(*Rails.groups)
```

**Fizzy equivalent**: Not currently needed, but this is where you'd fix boot crashes.

### Option 2: Initializer with on_load

**Use when**: Need to patch lazily-loaded Rails classes

```ruby
# config/initializers/active_job.rb
module FizzyActiveJobExtensions
  extend ActiveSupport::Concern

  prepended do
    attr_reader :account
  end

  def serialize
    super.merge("account" => @account&.to_gid)
  end
end

ActiveSupport.on_load(:active_job) do
  prepend FizzyActiveJobExtensions
end
```

**Why on_load**: ActiveJob::Base may not be loaded when the initializer runs. `on_load` waits until it's actually needed.

### Option 3: Initializer with after_initialize

**Use when**: Need Rails fully initialized first

```ruby
# config/initializers/tenanting/turbo.rb
module TurboStreamsJobExtensions
  extend ActiveSupport::Concern

  class_methods do
    def render_format(format, **rendering)
      if Current.account.present?
        ApplicationController.renderer.new(script_name: Current.account.slug).render(formats: [format], **rendering)
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

**Why after_initialize**: `Turbo::StreamsChannel` is defined by the turbo-rails gem, which needs Rails fully initialized.

### Option 4: to_prepare for Reloadable Code

**Use when**: Extending application classes that reload in development

```ruby
# config/initializers/uuid_framework_models.rb
Rails.application.config.to_prepare do
  ActionText::RichText.belongs_to :account, default: -> { record.account }
  ActiveStorage::Attachment.belongs_to :account, default: -> { record.account }
end
```

**Why to_prepare**: These associations need to be re-added when code reloads in development.

### Option 5: lib/rails_ext/ with Centralized Loading

**Use when**: Multiple related patches, loaded via initializer

```ruby
# lib/rails_ext/active_storage_analyze_job_suppress_broadcasts.rb
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

```ruby
# config/initializers/extensions.rb
Dir["#{Rails.root}/lib/rails_ext/*"].each { |path| require "rails_ext/#{File.basename(path)}" }
```

**Why this pattern**: Keeps patches organized and discoverable while using proper timing hooks.

---

## Examples from Fizzy

### Example 1: UUID Type Registration (Must Run Before AR Loads Tables)

```ruby
# lib/rails_ext/active_record_uuid_type.rb

module ActiveRecord::Type
  class Uuid < Binary
    # ... implementation ...
  end
end

# Register before any table schemas are loaded
ActiveRecord::Type.register(:uuid, ActiveRecord::Type::Uuid, adapter: :trilogy)
ActiveRecord::Type.register(:uuid, ActiveRecord::Type::Uuid, adapter: :sqlite3)
```

This runs when the file is required (via initializer), which is early enough because tables aren't accessed until first query.

### Example 2: Database Adapter Extensions (Conditional on Adapter Type)

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

**Why this timing**: The adapter classes exist after ActiveRecord loads, but we use `defined?` to check which one is actually in use.

### Example 3: Engine Initializers (Ordered Execution)

```ruby
# saas/lib/fizzy/saas/engine.rb

module Fizzy::Saas
  class Engine < ::Rails::Engine
    # Runs BEFORE other initializers
    initializer "fizzy_saas.content_security_policy", before: :load_config_initializers do |app|
      app.config.x.content_security_policy.form_action = "https://checkout.stripe.com"
    end

    # Runs AFTER routes are loaded
    initializer "fizzy.saas.routes", after: :add_routing_paths do |app|
      app.routes.prepend do
        # Add routes
      end
    end

    # Uses to_prepare for reloadable code
    config.to_prepare do
      ::Account.include Account::Billing
      ::Signup.prepend Fizzy::Saas::Signup
    end
  end
end
```

**Why engine initializers**: Rails engines have precise control over when their code runs relative to the main app and other gems.

---

## Debugging Boot Issues

### Technique 1: Identify the Crashing Gem

```bash
# Remove gems one at a time to find the culprit
bundle exec ruby -e "require 'bundler/setup'"  # Does this work?
bundle exec ruby -e "require 'rails/all'"       # Does this work?
bundle exec ruby -e "Bundler.require"           # Does this crash?
```

### Technique 2: Trace Requires

```ruby
# Add to config/boot.rb (temporarily)
module RequireTracer
  def require(path)
    puts "REQUIRE: #{path}"
    super
  end
end
Object.prepend(RequireTracer)
```

### Technique 3: Check Load Order

```ruby
# In Rails console or script
puts $LOADED_FEATURES.select { |f| f.include?('problematic_gem') }
```

### Technique 4: Inspect Gem Load Time

```ruby
# config/application.rb
require_relative "boot"
require "rails/all"

puts "=== BEFORE Bundler.require ==="
puts "Phlex defined? #{defined?(Phlex)}"

Bundler.require(*Rails.groups)

puts "=== AFTER Bundler.require ==="
puts "Phlex defined? #{defined?(Phlex)}"
```

---

## Summary

### Key Principles

1. **Stack traces reveal timing** - Look for `bundler/runtime.rb`, `<main>` frames, and initializer references
2. **Bundler.require is the danger zone** - Most gem crashes happen here, before any initializer runs
3. **Pre-Bundler patches are rare but necessary** - Place them in `config/application.rb` before `Bundler.require`
4. **Use appropriate hooks** - `on_load`, `after_initialize`, and `to_prepare` each serve different purposes
5. **Document extensively** - Explain why the patch is needed and link to relevant issues

### Quick Reference

| Symptom                               | Solution                                             |
| ------------------------------------- | ---------------------------------------------------- |
| Crash during `rails server` start     | Check if during Bundler.require -> pre-Bundler patch |
| Crash mentions gem file in `<main>`   | Pre-Bundler patch needed                             |
| Crash during initializer              | Fix in an earlier-loading initializer                |
| "undefined method" on Rails class     | Use `on_load` hook                                   |
| Patch doesn't take effect             | Check timing - may be too late                       |
| Patch breaks in development on reload | Use `to_prepare`                                     |

---

## Related Documentation

- [Extending Ruby and Rails](/docs/design/extending-ruby-rails.md) - Patterns for safe monkey patching
- [Rails Initialization Guide](https://guides.rubyonrails.org/initialization.html) - Official Rails documentation
- [ActiveSupport on_load hooks](https://api.rubyonrails.org/classes/ActiveSupport/LazyLoadHooks.html) - API reference
