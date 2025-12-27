# Gem Usage Guide

This document provides a comprehensive overview of all gems used in Fizzy, organized by category. Each entry explains what the gem does and where it is used in the codebase.

## Table of Contents

1. [Overview](#overview)
2. [Core Framework](#core-framework)
3. [Assets and Frontend](#assets-and-frontend)
4. [Deployment and Infrastructure](#deployment-and-infrastructure)
5. [Solid Family - Database-Backed Infrastructure](#solid-family---database-backed-infrastructure)
6. [Database Adapters](#database-adapters)
7. [Feature Gems](#feature-gems)
8. [Development and Test Gems](#development-and-test-gems)
9. [Summary Table](#summary-table)

---

## Overview

Fizzy uses **39 gems** across different categories. The gem selection reflects a "vanilla Rails" philosophy with database-backed infrastructure (via the Solid family) instead of external services like Redis or Elasticsearch.

Key architectural decisions reflected in gem choices:

- **No Redis** - Solid Queue, Solid Cache, and Solid Cable provide database-backed alternatives
- **No Elasticsearch** - Custom 16-shard MySQL full-text search with Mittens for stemming
- **Importmap over bundlers** - Modern ES modules without Webpack/esbuild complexity
- **Passwordless authentication** - Magic links instead of bcrypt password hashing

---

## Core Framework

### rails (main branch)

The full Rails 8.1 stack with all components enabled.

**Configuration**: `config/application.rb`

```ruby
# UUID primary keys by default
config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
```

**Components used**:
- Action Cable (real-time updates via Solid Cable)
- Active Storage (file attachments)
- Action Mailer (magic link emails, notifications)
- Action Text (rich text editing)

---

## Assets and Frontend

### importmap-rails

JavaScript module loading without bundling. Pins packages directly from CDNs or vendored files.

**Location**: `config/importmap.rb`

```ruby
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@rails/request.js", to: "@rails--request.js"
pin "@rails/activestorage", to: "activestorage.esm.js"
pin "@rails/actiontext", to: "actiontext.esm.js"
pin "marked"  # Markdown rendering
pin "lexxy"   # Rich text editor
```

Auto-pins all Stimulus controllers from `app/javascript/controllers/`.

### propshaft

Modern asset pipeline replacement for Sprockets. Handles CSS, images, and static assets with fingerprinting.

**Configuration**: `config/initializers/assets.rb`

### stimulus-rails

JavaScript controller framework for progressive enhancement.

**Location**: `app/javascript/controllers/` (57 controllers)

Controllers handle:
- Drag-and-drop (`sortable_controller.js`)
- Modal dialogs (`dialog_controller.js`)
- Form validation and submission
- Tooltips and popovers
- Keyboard shortcuts (`hotkey_controller.js`)
- Push notifications (`push_subscription_controller.js`)
- Theme switching (`theme_controller.js`)
- Syntax highlighting (`code_highlight_controller.js`)

**Initialization**: `app/javascript/controllers/application.js`

### turbo-rails

SPA-like navigation and real-time updates via Turbo Drive, Frames, and Streams.

**Usage patterns**:

Broadcasting notifications:
```ruby
# app/models/notification.rb:42
broadcast_prepend_later_to [user, :notifications], ...
```

Suppressing broadcasts during batch operations:
```ruby
# script/populate.rb
suppressing_turbo_broadcasts do
  # Create many records without flooding broadcasts
end
```

Turbo Frames for partial page updates, Turbo Streams for server-pushed DOM changes.

---

## Deployment and Infrastructure

### bootsnap

Boot time optimization through caching of expensive operations.

**Location**: `config/boot.rb:4`

```ruby
require "bootsnap/setup"
```

Caches:
- Ruby bytecode compilation
- `require` path resolution
- YAML parsing

### kamal

Docker-based deployment orchestration.

**Location**: `config/deploy.yml`

```yaml
service: fizzy
image: fizzy
servers:
  web:
    hosts:
      - 192.168.1.1
volumes:
  - /data/fizzy/storage:/rails/storage
```

Features:
- SSL proxy configuration
- Volume mounts for SQLite storage
- Environment secrets (VAPID keys, SMTP credentials)
- Local registry at `localhost:5555`

### puma

High-performance Ruby web server.

**Location**: `config/puma.rb`

```ruby
# Production configuration
workers ENV.fetch("WEB_CONCURRENCY") { Etc.nprocessors }
threads 1, 1  # 1 thread per worker

# Solid Queue integration
plugin :solid_queue

# GC optimizations
on_worker_boot do
  Process.warmup
end

before_fork do
  4.times { GC.start(full_mark: false) }
end
```

### thruster

HTTP/2 proxy for caching and compression. Sits in front of Puma in production.

Listed in Gemfile; configuration is external to Rails.

### autotuner

Automatic garbage collection tuning with logging.

**Location**: `config/initializers/autotuner.rb`

```ruby
Autotuner.reporter = proc do |report|
  Rails.logger.info("GCAUTOTUNE: #{report}")
end
```

Reports heuristics for heap optimization to help identify memory issues.

### mission_control-jobs

Web UI for monitoring Solid Queue background jobs.

**Location**: `config/initializers/mission_control.rb`

```ruby
MissionControl::Jobs.base_controller_class = "AdminController"
MissionControl::Jobs.show_console_help = false
```

Mounted at `/admin/jobs` for job monitoring, retry management, and queue inspection.

---

## Solid Family - Database-Backed Infrastructure

These gems replace Redis and external services with database-backed implementations, simplifying deployment and reducing operational complexity.

### solid_queue

Database-backed job queue. Replaces Sidekiq/Resque without Redis.

**Configuration**: `config/queue.yml`

```yaml
production:
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [default, solid_queue_recurring, backend, webhooks]
      threads: 5
      polling_interval: 0.5
```

**Recurring tasks**: `config/recurring.yml`

```yaml
deliver_bundled_notifications:
  class: Notifications::DeliverBundledJob
  schedule: every 30 minutes

auto_postpone_all_due:
  class: Cards::Entropy::AutoPostponeAllDueJob
  schedule: every hour at minute 50

delete_unused_tags:
  class: Tags::DeleteUnusedJob
  schedule: every day at 04:02
```

**Custom extensions**: `config/initializers/active_job.rb`

```ruby
module FizzyActiveJobExtensions
  # Preserves Current.account across job serialization
  def serialize
    super.merge("account" => @account&.to_gid&.to_s)
  end

  def deserialize(job_data)
    super
    @account = GlobalID::Locator.locate(job_data["account"])
  end
end
```

### solid_cache

Database-backed caching. Replaces Redis or Memcached.

**Configuration**: `config/cache.yml`

```yaml
production:
  database: cache
  max_age: <%= 60.days.to_i %>
  namespace: <%= Rails.env %>
```

Uses a dedicated `cache` database to avoid bloating the primary database.

### solid_cable

Database-backed Action Cable adapter for WebSocket pub/sub.

**Configuration**: `config/cable.yml`

```yaml
production:
  adapter: solid_cable
  polling_interval: 0.1.seconds
  message_retention: 1.day
```

Uses a dedicated `cable` database with short message retention for real-time updates.

---

## Database Adapters

### sqlite3

SQLite adapter for local development and single-server deployments.

**Configuration**: `config/database.sqlite.yml`

```yaml
default: &default
  adapter: sqlite3
  pool: 5
  timeout: 5000

development:
  primary:
    <<: *default
    database: storage/development.sqlite3
  cable:
    <<: *default
    database: storage/development_cable.sqlite3
  cache:
    <<: *default
    database: storage/development_cache.sqlite3
  queue:
    <<: *default
    database: storage/development_queue.sqlite3
```

### trilogy

MySQL adapter for SaaS and multi-server deployments.

**Configuration**: `config/database.mysql.yml`

```yaml
default: &default
  adapter: trilogy
  pool: 50
  ssl: true
  ssl_mode: required
```

Used in production with MySQL for better scalability and replication support.

---

## Feature Gems

### bcrypt

Password hashing library. Listed in Gemfile for potential use, but Fizzy primarily uses passwordless magic link authentication.

### geared_pagination

Simple, sensible pagination for Rails.

**Usage**: 21 controllers

```ruby
# Pattern used throughout
set_page_and_extract_portion_from @collection

# Controllers using it:
# TagsController, UsersController, WebhooksController
# SearchesController, NotificationsController
# CardsController, BoardsController, CommentsController, etc.
```

### rqrcode

QR code generation for shareable links.

**Location**: `app/controllers/qr_codes_controller.rb:7`

```ruby
def show
  qrcode = RQRCode::QRCode.new(params[:url])
  svg = qrcode.as_svg(
    color: "000",
    shape_rendering: "crispEdges",
    module_size: 6,
    viewbox: true
  )

  expires_in 1.year, public: true
  render inline: svg, content_type: "image/svg+xml"
end
```

### redcarpet and rouge

Markdown rendering and syntax highlighting.

Listed in Gemfile for Markdown processing. May be used via Lexxy or JavaScript-side rendering with the `marked` library.

### jbuilder

JSON template rendering for API responses.

**Location**: 28 `.json.jbuilder` templates

Templates for:
- `boards/`, `cards/`, `columns/`
- `comments/`, `reactions/`, `steps/`
- `tags/`, `users/`, `notifications/`
- `webhooks/` and webhook payloads

Example:
```ruby
# app/views/cards/show.json.jbuilder
json.extract! @card, :id, :number, :title, :state
json.board_id @card.board_id
json.column_id @card.column_id
# ...
```

### lexxy (Basecamp gem)

Rich text editor with autocomplete prompts.

**Location**: `app/helpers/rich_text_helper.rb`, `config/importmap.rb`

```ruby
# Prompts configuration
prompts: {
  "@" => { url: mentions_path, key: "mentions" },
  "#" => { url: tags_path, key: "tags" },
  "##" => { url: cards_path, key: "cards" }
}
```

Features:
- `@mentions` for user mentions
- `#tags` for tag completion
- `##cards` for card references
- Code language picker for syntax highlighting

### image_processing

Active Storage image variant processing.

**Locations**:
- `app/models/user/avatar.rb`
- `app/models/concerns/attachments.rb`

```ruby
# Avatar variants
has_one_attached :avatar do |attachable|
  attachable.variant :thumb, resize_to_fill: [64, 64]
  attachable.variant :medium, resize_to_fill: [128, 128]
end
```

Uses vips (configured in `config/initializers/vips.rb`) for fast image processing.

### platform_agent

User agent parsing for device and platform detection.

**Location**: `app/models/application_platform.rb`

```ruby
class ApplicationPlatform < PlatformAgent
  # Detects: iOS, Android, Mac, Windows
  # Browsers: Chrome, Firefox, Safari, Edge
  # Identifies native Hotwire apps vs mobile/desktop web
end
```

### aws-sdk-s3

S3-compatible storage for Active Storage in production.

**Configuration**: `config/storage.oss.yml`

```yaml
amazon:
  service: S3
  access_key_id: <%= ENV["AWS_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
  region: us-east-1
  bucket: fizzy-production

devminio:
  service: S3
  access_key_id: minioadmin
  secret_access_key: minioadmin
  endpoint: http://localhost:9000
  bucket: fizzy-dev
  force_path_style: true
```

Supports MinIO for local development testing of S3 workflows.

### web-push

Web Push notifications via VAPID protocol.

**Locations**:
- `config/initializers/web_push.rb`
- `lib/web_push/pool.rb`

```ruby
# Custom thread pool for push delivery
WebPush::Pool.new(
  pool_size: 50,
  connections: 150
)
```

Features:
- Thread pool with 50 threads for concurrent delivery
- Connection pooling via `Net::HTTP::Persistent`
- Auto-destroys expired subscriptions
- Patched `WebPush::Request.perform` for persistent connections

### net-http-persistent

HTTP connection pooling for web push delivery.

**Location**: `lib/web_push/pool.rb:8`

```ruby
@http = Net::HTTP::Persistent.new(name: "web-push")
@http.open_timeout = 5
@http.read_timeout = 5
```

Reduces SSL handshake overhead by reusing connections (150 connection pool).

### rubyzip

ZIP file creation for account data exports.

**Location**: `app/models/account/export.rb:43`

```ruby
Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
  cards.find_each do |card|
    zipfile.add("cards/#{card.number}.json", card_json_path(card))
    card.attachments.each do |attachment|
      zipfile.add("cards/#{card.number}/#{attachment.filename}", attachment.path)
    end
  end
end
```

Exports cards with JSON metadata and attachments.

### mittens

Word stemming for full-text search.

**Location**: `app/models/search/stemmer.rb:4`

```ruby
class Search::Stemmer
  def initialize
    @stemmer = Mittens::Stemmer.new
  end

  def stem(word)
    @stemmer.stem(word)
  end
end
```

Normalizes search terms for better full-text search matching (e.g., "running" -> "run").

### useragent (Basecamp gem)

User agent string parsing. Used internally by `platform_agent` gem.

### benchmark

Indirect dependency for Ruby 3.5+ compatibility. Prevents warnings about stdlib removal.

---

## Development and Test Gems

### brakeman

Static security analysis for Rails applications.

**Usage**: `bin/ci` step

```bash
bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
```

Scans for:
- SQL injection vulnerabilities
- Cross-site scripting (XSS)
- Mass assignment issues
- Insecure redirects

### bundler-audit

Gem vulnerability scanning.

**Usage**: `bin/ci` step

```bash
bin/bundler-audit check --update
```

Checks Gemfile.lock against known CVE database.

### debug

Ruby 3+ debugger. Provides `binding.break` for interactive debugging.

### faker

Test data generation.

**Location**: `script/populate.rb`

```ruby
Faker::Company.name
Faker::Company.buzzword
Faker::Hacker.say_something_smart
Faker::Game.title
Faker::FunnyName.name
```

Generates realistic test data for development and seeding.

### letter_opener

Email preview in browser during development.

**Location**: `config/environments/development.rb:82`

```ruby
if File.exist?("tmp/email-dev.txt")
  config.action_mailer.delivery_method = :letter_opener
end
```

Toggle via `tmp/email-dev.txt` file presence.

### rack-mini-profiler

Performance profiling and timing display.

**Location**: `config/initializers/rack_mini_profiler.rb`

```ruby
if File.exist?("tmp/rack-mini-profiler-dev.txt")
  Rack::MiniProfiler.config.position = "bottom-right"
  Rack::MiniProfiler.config.start_hidden = true
end
```

Features:
- SQL query timing
- View render timing
- Turbo Drive support
- Toggle via `tmp/rack-mini-profiler-dev.txt`

### rubocop-rails-omakase

37signals' opinionated Ruby style guide.

**Location**: `.rubocop.yml`

```yaml
inherit_gem:
  rubocop-rails-omakase: rubocop.yml

AllCops:
  Exclude:
    - db/migrate/**/*
    - db/schema.rb
```

Enforces consistent code style across the codebase.

### web-console

In-browser Rails console for development errors. Automatically enabled in development when exceptions occur.

### capybara

Browser testing framework for system tests.

**Location**: `test/application_system_test_case.rb`

```ruby
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1000]
end
```

### selenium-webdriver

Chrome browser automation for system tests.

**Location**: `test/application_system_test_case.rb`

```ruby
Capybara.register_driver :headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless")
  options.add_argument("--disable-gpu")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--window-size=1400,1000")

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end
```

### webmock

HTTP request stubbing for tests.

**Location**: `test/test_helper.rb:5`

```ruby
require "webmock/minitest"
WebMock.allow_net_connect!
```

Allows connections by default; can stub specific endpoints for isolated testing.

### vcr

HTTP recording and playback for deterministic tests.

**Location**: `test/test_helper.rb:12-37`

```ruby
VCR.configure do |config|
  config.cassette_library_dir = "test/cassettes"
  config.hook_into :webmock
  config.filter_sensitive_data("<OPENAI_API_KEY>") { ENV["OPENAI_API_KEY"] }
end
```

Features:
- Records HTTP interactions to cassettes
- Filters sensitive data (API keys)
- Normalizes timestamps for reproducibility

### mocha

Mocking and stubbing library.

**Location**: `test/test_helper.rb:7`

```ruby
require "mocha/minitest"
```

Integrated with Minitest for mock objects and method stubs.

---

## Summary Table

| Category | Gem | Primary Use |
|----------|-----|-------------|
| **Framework** | rails | Full-stack web framework |
| **Frontend** | importmap-rails | JS module loading without bundler |
| | propshaft | Asset pipeline |
| | stimulus-rails | JS controllers (57 total) |
| | turbo-rails | SPA-like navigation, broadcasts |
| **Database** | sqlite3 | Local/OSS database |
| | trilogy | MySQL for SaaS |
| **Jobs** | solid_queue | Background job processing |
| | solid_cache | Database-backed caching |
| | solid_cable | Action Cable adapter |
| **Deploy** | kamal | Docker deployment |
| | puma | Web server |
| | bootsnap | Boot optimization |
| | thruster | HTTP/2 proxy |
| | autotuner | GC tuning |
| | mission_control-jobs | Job monitoring UI |
| **Features** | jbuilder | JSON APIs |
| | geared_pagination | Pagination |
| | rqrcode | QR codes |
| | lexxy | Rich text editor |
| | image_processing | Image variants |
| | platform_agent | Device detection |
| | aws-sdk-s3 | Cloud storage |
| | web-push | Push notifications |
| | net-http-persistent | Connection pooling |
| | rubyzip | ZIP exports |
| | mittens | Search stemming |
| | redcarpet | Markdown rendering |
| | rouge | Syntax highlighting |
| | bcrypt | Password hashing (available) |
| | useragent | User agent parsing |
| | benchmark | Ruby 3.5+ compatibility |
| **Dev/Test** | capybara | Browser testing framework |
| | selenium-webdriver | Chrome automation |
| | webmock | HTTP mocking |
| | vcr | HTTP recording/playback |
| | mocha | Stubbing |
| | faker | Test data generation |
| | brakeman | Security scanning |
| | bundler-audit | Gem vulnerability scanning |
| | rubocop-rails-omakase | Linting |
| | rack-mini-profiler | Performance profiling |
| | letter_opener | Email preview |
| | web-console | In-browser console |
| | debug | Ruby debugger |

---

## Key Takeaways

### Philosophy

1. **Database-backed infrastructure** - Solid Queue, Solid Cache, and Solid Cable eliminate Redis dependency
2. **No external search** - Custom sharded MySQL full-text search instead of Elasticsearch
3. **Modern frontend without complexity** - Importmap + Stimulus + Turbo over Webpack/React
4. **Vanilla Rails** - Thin controllers, rich models, minimal service objects

### Deployment Simplicity

The gem selection enables single-server deployments with SQLite or multi-server deployments with MySQL, without changing application code. All state lives in the database, making horizontal scaling straightforward.

### Testing Infrastructure

Comprehensive testing support with:
- Capybara + Selenium for browser tests
- WebMock + VCR for HTTP mocking
- Faker for realistic test data
- Mocha for mocking/stubbing

For additional details on specific gems, explore their usage in the codebase or consult the gem documentation.
