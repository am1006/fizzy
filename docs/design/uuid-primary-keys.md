# UUID Primary Keys

Fizzy uses UUIDv7 primary keys stored as compact binary data with a base36 string representation in Ruby. This design provides time-sortable, URL-friendly identifiers while maintaining storage efficiency.

---

## Overview

Traditional auto-incrementing integer IDs have drawbacks: they expose record counts, enable enumeration attacks, and complicate distributed systems. Fizzy addresses these issues with UUIDs while avoiding the typical downsides of UUID primary keys (poor sorting, large storage, unwieldy strings).

**Design goals:**
- Time-sortable IDs (newer records have "larger" IDs)
- Compact storage (16 bytes, same as two bigints)
- URL-friendly representation (no dashes or special characters)
- Automatic generation (no manual ID assignment)
- Predictable test ordering (fixtures sort correctly)

---

## Why UUIDs as Primary Keys?

A **primary key** is simply a column that uniquely identifies each row in a table. It doesn't have to be an integer - it can be any data type that guarantees uniqueness.

### Primary Key Options

| Type | Example | Common Use |
|------|---------|------------|
| Integer (auto-increment) | `1, 2, 3, 4...` | Traditional Rails default |
| UUID | `550e8400-e29b-41d4-...` | Distributed systems, security |
| String | `"user_abc123"` | Readable IDs (Stripe, etc.) |
| Composite | `(user_id, post_id)` | Join tables |

### Why Integers Became the Default

Integers were the traditional choice due to historical database optimizations:

```ruby
# Traditional Rails
create_table :cards do |t|  # implicitly creates integer `id`
  t.string :title
end
# Results in: id: 1, 2, 3, 4, 5...
```

**Pros of integers:**
- Small storage (4-8 bytes)
- Fast comparisons
- Simple auto-increment

**Cons of integers:**
- Expose how many records exist (`/users/5` = 5th user)
- Predictable (easy to guess `/users/6`)
- Hard in distributed systems (two servers might create `id: 1000` simultaneously)

### Why Fizzy Uses UUIDs

```ruby
# Fizzy's approach
create_table :cards, id: :uuid do |t|
  t.string :title
end
# Results in: id: "01jcqzx8h0000000000000000", "01jcqzx9a0000000000000001"...
```

**Pros of UUIDs:**
- No information leakage (can't guess other IDs)
- Globally unique (can generate anywhere, merge databases safely)
- With UUIDv7: still time-sortable like integers

**Cons of UUIDs:**
- Larger storage (16 bytes vs 4-8 bytes)
- Longer URLs (mitigated by base36 encoding)

### Visual Comparison

```
Integer Primary Key:
┌────────┬─────────────┐
│ id     │ title       │
├────────┼─────────────┤
│ 1      │ First card  │  <- Attacker knows: "only 3 cards exist"
│ 2      │ Second card │  <- Attacker can try: /cards/4, /cards/5...
│ 3      │ Third card  │
└────────┴─────────────┘

UUID Primary Key:
┌───────────────────────────┬─────────────┐
│ id                        │ title       │
├───────────────────────────┼─────────────┤
│ 01jcqzx8h0000000000000000 │ First card  │  <- No count revealed
│ 01jd2abc1230000000000000  │ Second card │  <- Can't guess other IDs
│ 01jf9xyz4560000000000000  │ Third card  │
└───────────────────────────┴─────────────┘
```

### It's Still a Primary Key

The database still enforces the same rules:

```sql
-- SQLite with UUID
CREATE TABLE cards (
  id BLOB(16) PRIMARY KEY,  -- Still a primary key!
  title TEXT
);

-- PostgreSQL with UUID
CREATE TABLE cards (
  id UUID PRIMARY KEY,      -- Still a primary key!
  title TEXT
);
```

The database guarantees:
- **Uniqueness** - No two rows can have the same `id`
- **Not null** - Every row must have an `id`
- **Indexed** - Fast lookups by `id`

### Rails Makes It Transparent

With Fizzy's setup, you use UUIDs exactly like integer IDs:

```ruby
# Creating - ID auto-generated (just like integers)
card = Card.create!(title: "My card")
card.id  # => "01jcqzx8h0000000000000000"

# Finding - works the same
Card.find("01jcqzx8h0000000000000000")

# Associations - work the same
class Card < ApplicationRecord
  belongs_to :board  # board_id is also a UUID
  has_many :comments
end

# URLs - work the same
card_path(card)  # => "/cards/01jcqzx8h0000000000000000"
```

### Common Misconceptions

| Myth | Reality |
|------|---------|
| "Primary keys must be integers" | Primary keys can be any unique value |
| "UUIDs can't be sorted" | UUIDv7 is time-sortable (newer = larger) |
| "UUIDs are random gibberish" | UUIDv7 embeds a timestamp, base36 makes them shorter |

---

## Key Concepts

### UUIDv7

UUIDv7 is a time-based UUID format (RFC 9562) that embeds a Unix timestamp in the first 48 bits. Unlike UUIDv4 (random), UUIDv7 IDs are monotonically increasing over time. This means:

- Records created later have lexicographically larger IDs
- `.first` and `.last` work intuitively
- B-tree indexes remain efficient (no random insertions)

### Base36 Encoding

Instead of the standard hex format (`550e8400-e29b-41d4-a716-446655440000`), Fizzy encodes UUIDs as 25-character base36 strings using digits 0-9 and letters a-z:

```
01jcqzx8h0000000000000000
```

**Benefits:**
- Shorter than hex (25 chars vs 32 chars without dashes)
- URL-safe (no special characters)
- Case-insensitive friendly
- Still sorts correctly (lexicographic order matches numeric order)

### Storage Strategy

UUIDs are stored differently depending on the database:

| Database | Storage Type | Notes |
|----------|--------------|-------|
| SQLite | `blob(16)` | 16-byte binary blob |
| PostgreSQL | `uuid` | Native 128-bit UUID type |

Both provide:
- Same storage as two bigint columns (16 bytes)
- Efficient indexing and comparisons
- No character set overhead

---

## Architecture

```
                    Ruby Application
                          |
                          v
              +------------------------+
              |  Base36 String (25ch)  |  <-- What you see in code
              |  "01jcqzx8h0000000..." |
              +------------------------+
                          |
                          v
              +------------------------+
              |  ActiveRecord::Type::  |  <-- Custom type handles conversion
              |        Uuid            |
              +------------------------+
                          |
            +-------------+-------------+
            |                           |
            v                           v
    +---------------+           +---------------+
    | SQLite        |           | PostgreSQL    |
    | blob(16)      |           | uuid (native) |
    +---------------+           +---------------+
```

---

## Implementation Details

### Custom UUID Type

**File:** `lib/rails_ext/active_record_uuid_type.rb`

The core of the implementation is a custom ActiveRecord type. The base implementation handles binary storage (SQLite), while PostgreSQL uses a specialized subclass for its native uuid type:

```ruby
module ActiveRecord
  module Type
    class Uuid < Binary
      BASE36_LENGTH = 25 # 36^25 > 2^128

      class << self
        def generate
          uuid = SecureRandom.uuid_v7
          hex = uuid.delete("-")
          hex_to_base36(hex)
        end

        def hex_to_base36(hex)
          hex.to_i(16).to_s(36).rjust(BASE36_LENGTH, "0")
        end

        def base36_to_hex(base36)
          base36.to_s.to_i(36).to_s(16).rjust(32, "0")
        end
      end

      def serialize(value)
        return unless value

        binary = Uuid.base36_to_hex(value).scan(/../).map(&:hex).pack("C*")
        super(binary)
      end

      def deserialize(value)
        return unless value

        hex = value.to_s.unpack1("H*")
        Uuid.hex_to_base36(hex)
      end

      def cast(value)
        value
      end
    end

    # PostgreSQL-specific UUID type
    # PostgreSQL has native uuid support, so we work with hex strings instead of binary
    class PostgresUuid < Value
      class << self
        delegate :generate, :hex_to_base36, :base36_to_hex, to: Uuid
      end

      def serialize(value)
        return unless value

        # PostgreSQL expects standard UUID format (hex with dashes)
        hex = self.class.base36_to_hex(value)
        "#{hex[0,8]}-#{hex[8,4]}-#{hex[12,4]}-#{hex[16,4]}-#{hex[20,12]}"
      end

      def deserialize(value)
        return unless value

        # PostgreSQL returns standard UUID format
        hex = value.to_s.delete("-")
        self.class.hex_to_base36(hex)
      end

      def cast(value)
        value
      end
    end
  end
end

# Register for database adapters
ActiveRecord::Type.register(:uuid, ActiveRecord::Type::Uuid, adapter: :sqlite3)
ActiveRecord::Type.register(:uuid, ActiveRecord::Type::PostgresUuid, adapter: :postgresql)
```

**Conversion flow:**

SQLite (binary storage):
- **Ruby to Database:** base36 string -> hex string -> 16-byte binary
- **Database to Ruby:** 16-byte binary -> hex string -> base36 string

PostgreSQL (native uuid):
- **Ruby to Database:** base36 string -> hex string -> UUID format with dashes
- **Database to Ruby:** UUID format with dashes -> hex string -> base36 string

### Database Adapters

**File:** `config/initializers/uuid_primary_keys.rb`

The adapters teach SQLite and PostgreSQL to recognize UUID columns:

#### SQLite Adapter

```ruby
module SqliteUuidAdapter
  extend ActiveSupport::Concern

  def lookup_cast_type(sql_type)
    if sql_type == "blob(16)"
      ActiveRecord::Type.lookup(:uuid, adapter: :sqlite3)
    else
      super
    end
  end

  class_methods do
    def native_database_types
      @native_database_types_with_uuid ||= super.merge(uuid: { name: "blob", limit: 16 })
    end
  end
end
```

#### PostgreSQL Adapter

PostgreSQL has native UUID support, so the adapter is simpler:

```ruby
module PostgresUuidAdapter
  extend ActiveSupport::Concern

  # PostgreSQL already understands 'uuid' type natively
  # We just need to ensure our custom type is used for serialization

  def lookup_cast_type(sql_type)
    if sql_type == "uuid"
      ActiveRecord::Type.lookup(:uuid, adapter: :postgresql)
    else
      super
    end
  end

  class_methods do
    def native_database_types
      # PostgreSQL already has uuid in native_database_types
      # This ensures migrations use the native uuid type
      super
    end
  end
end
```

#### Loading the Adapters

```ruby
# For SQLite
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteUuidAdapter)
  ActiveRecord::ConnectionAdapters::SQLite3::SchemaDumper.prepend(SchemaDumperUuidType)
end

# For PostgreSQL
ActiveSupport.on_load(:active_record_postgresqladapter) do
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(PostgresUuidAdapter)
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SchemaDumperUuidType)
end
```

### Automatic Default Generation

**File:** `config/initializers/uuid_primary_keys.rb`

When a model's schema loads, if the primary key is `:uuid` type, a default value generator is automatically attached:

```ruby
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
      table_name && primary_key &&
        schema_cache.columns_hash(table_name)[primary_key]&.type == :uuid
    end

    PendingUuidDefault = Struct.new(:name) do
      def apply_to(attribute_set)
        attribute_set[name] = attribute_set[name].with_user_default(
          -> { ActiveRecord::Type::Uuid.generate }
        )
      end
    end
end
```

This means you never manually set IDs:

```ruby
card = Card.create!(title: "New card")
card.id  # => "01jcqzx8h0000000000000000" (auto-generated)
```

### Schema Dumper Integration

The schema dumper is patched to output `:uuid` type instead of the underlying storage type:

```ruby
module SchemaDumperUuidType
  def schema_type(column)
    if column.sql_type == "blob(16)" || column.sql_type == "uuid"
      :uuid
    else
      super
    end
  end
end
```

This produces clean, readable schema files:

```ruby
create_table "cards", id: :uuid do |t|
  t.uuid "board_id", null: false
  t.uuid "creator_id", null: false
  t.string "title"
  t.timestamps
end
```

### Fixture UUID Generation

**File:** `test/test_helper.rb`

A common problem with UUID fixtures: since UUIDs are typically random, `.first` and `.last` return unpredictable results in tests. Fizzy solves this with deterministic, time-ordered fixture UUIDs:

```ruby
module FixturesTestHelper
  extend ActiveSupport::Concern

  class_methods do
    def identify(label, column_type = :integer)
      if label.to_s.end_with?("_uuid")
        column_type = :uuid
        label = label.to_s.delete_suffix("_uuid")
      end

      return super(label, column_type) unless column_type.in?([ :uuid, :string ])
      generate_fixture_uuid(label)
    end

    private

    def generate_fixture_uuid(label)
      # Use CRC32 for deterministic ordering (matches Rails' integer ID generation)
      fixture_int = Zlib.crc32("fixtures/#{label}") % (2**30 - 1)

      # Map to timestamps in the past so runtime records are always newer
      base_time = Time.utc(2024, 1, 1, 0, 0, 0)
      timestamp = base_time + (fixture_int / 1000.0)

      uuid_v7_with_timestamp(timestamp, label)
    end

    def uuid_v7_with_timestamp(time, seed_string)
      # Build UUIDv7 with custom timestamp and deterministic random bits
      time_ms = time.to_f * 1000
      timestamp_ms = time_ms.to_i

      bytes = []
      # 48-bit timestamp (milliseconds since epoch)
      bytes[0] = (timestamp_ms >> 40) & 0xff
      bytes[1] = (timestamp_ms >> 32) & 0xff
      bytes[2] = (timestamp_ms >> 24) & 0xff
      bytes[3] = (timestamp_ms >> 16) & 0xff
      bytes[4] = (timestamp_ms >> 8) & 0xff
      bytes[5] = timestamp_ms & 0xff

      # 12-bit sub-millisecond precision for ordering within same millisecond
      frac_ms = time_ms - timestamp_ms
      sub_ms_precision = (frac_ms * 4096).to_i & 0xfff

      # Deterministic "random" bits from label hash
      hash = Digest::MD5.hexdigest(seed_string)

      bytes[6] = ((sub_ms_precision >> 8) & 0x0f) | 0x70  # version 7
      bytes[7] = sub_ms_precision & 0xff

      rand_b = hash[3...19].to_i(16) & ((2**62) - 1)
      bytes[8] = ((rand_b >> 56) & 0x3f) | 0x80  # variant 10
      bytes[9] = (rand_b >> 48) & 0xff
      bytes[10] = (rand_b >> 40) & 0xff
      bytes[11] = (rand_b >> 32) & 0xff
      bytes[12] = (rand_b >> 24) & 0xff
      bytes[13] = (rand_b >> 16) & 0xff
      bytes[14] = (rand_b >> 8) & 0xff
      bytes[15] = rand_b & 0xff

      uuid = "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % bytes
      ActiveRecord::Type::Uuid.hex_to_base36(uuid.delete("-"))
    end
  end
end

ActiveSupport.on_load(:active_record_fixture_set) do
  prepend(FixturesTestHelper)
end
```

**Key behaviors:**

1. **Deterministic:** Same fixture label always generates same UUID
2. **Ordered:** UUIDs sort in same order as Rails' integer fixture IDs (uses same CRC32 algorithm)
3. **In the past:** All fixture timestamps are in 2024, so runtime records (using current time) are always "newer"

Usage in fixtures:

```yaml
# test/fixtures/accounts.yml
37s:
  id: <%= ActiveRecord::FixtureSet.identify("37s", :uuid) %>
  name: 37signals
```

---

## Examples

### Migration

Migrations work identically for both databases:

```ruby
class CreateCards < ActiveRecord::Migration[8.2]
  def change
    create_table :cards, id: :uuid do |t|
      t.uuid :board_id, null: false
      t.uuid :creator_id, null: false
      t.string :title
      t.timestamps

      t.index :board_id
      t.index :creator_id
    end
  end
end
```

Rails translates `id: :uuid` and `t.uuid` to the appropriate type:
- **SQLite:** `blob(16)`
- **PostgreSQL:** `uuid` (native)

### Model Usage

```ruby
class Card < ApplicationRecord
  belongs_to :board
  belongs_to :creator, class_name: "User"
end

# IDs are auto-generated
card = Card.create!(board: board, creator: user, title: "My card")
card.id  # => "01jd2abc123..."

# Ordering works correctly
Card.first  # Returns oldest card (by creation time)
Card.last   # Returns newest card
Card.order(:id)  # Orders by creation time
```

### Querying

```ruby
# Find by ID (works normally)
Card.find("01jd2abc123...")

# ID comparisons work for time-based queries
Card.where("id > ?", some_card.id)  # Cards created after some_card
```

---

## Migrating from SQLite to PostgreSQL

When you outgrow SQLite and need to migrate to PostgreSQL, the UUID system makes this straightforward since both store the same 128-bit values.

### Migration Script

```ruby
class MigrateToPostgresql < ActiveRecord::Migration[8.2]
  def up
    # For each table with UUID columns, convert blob(16) to native uuid
    # The 16-byte binary data maps directly to PostgreSQL's uuid type

    execute <<~SQL
      -- PostgreSQL interprets the 16 bytes as a UUID
      ALTER TABLE cards
        ALTER COLUMN id TYPE uuid USING encode(id, 'hex')::uuid,
        ALTER COLUMN board_id TYPE uuid USING encode(board_id, 'hex')::uuid,
        ALTER COLUMN creator_id TYPE uuid USING encode(creator_id, 'hex')::uuid;
    SQL
  end
end
```

### What Changes

| Aspect | Before (SQLite) | After (PostgreSQL) |
|--------|-----------------|-------------------|
| Column type | `blob(16)` | `uuid` |
| Storage | 16 bytes | 16 bytes |
| Ruby representation | Base36 (25 chars) | Base36 (25 chars) |
| URLs | `/cards/01jcqzx8h...` | `/cards/01jcqzx8h...` |

### What Stays the Same

- All Ruby code (models, controllers, views)
- URL structure (base36 encoding preserved)
- Fixture generation
- ID ordering behavior
- All existing IDs (data migrates 1:1)

---

## PostgreSQL-Specific Features

PostgreSQL's native UUID type enables some additional capabilities:

### Database-Level Generation (Optional)

If you want the database to generate UUIDs (useful for raw SQL inserts), you can use the `pgcrypto` extension:

```ruby
class EnablePgcrypto < ActiveRecord::Migration[8.2]
  def up
    enable_extension 'pgcrypto'
  end
end

class CreateCards < ActiveRecord::Migration[8.2]
  def change
    create_table :cards, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # ...
    end
  end
end
```

**Note:** `gen_random_uuid()` generates UUIDv4 (random), not UUIDv7 (time-ordered). For UUIDv7 at the database level, you'd need the `pg_uuidv7` extension or continue using Ruby-based generation.

### UUID Functions in SQL

PostgreSQL provides helpful UUID functions:

```sql
-- Check if a value is a valid UUID
SELECT 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid;

-- Generate random UUID (v4)
SELECT gen_random_uuid();

-- Compare UUIDs
SELECT * FROM cards WHERE id > 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid;
```

---

## Related Systems

- **Multi-tenancy:** All models include `account_id` (also a UUID) for tenant isolation
- **Events:** Event records use UUIDs, enabling distributed event sourcing
- **Search sharding:** Account IDs (UUIDs) are hashed to determine search shard

---

## Porting to Another Project

To implement this UUID system in another Rails application:

### 1. Create the UUID Type

Copy `lib/rails_ext/active_record_uuid_type.rb` to your project. Include both `Uuid` (for SQLite) and `PostgresUuid` (for PostgreSQL) classes.

### 2. Create the Initializer

Copy `config/initializers/uuid_primary_keys.rb` and configure the adapter hooks:

```ruby
# For SQLite (development/test)
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(SqliteUuidAdapter)
  ActiveRecord::ConnectionAdapters::SQLite3::SchemaDumper.prepend(SchemaDumperUuidType)
end

# For PostgreSQL (production)
ActiveSupport.on_load(:active_record_postgresqladapter) do
  ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(PostgresUuidAdapter)
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SchemaDumperUuidType)
end
```

### 3. Configure Generators

In `config/application.rb`:

```ruby
config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
```

### 4. Add Test Helper (Optional)

Copy the `FixturesTestHelper` module to `test/test_helper.rb` if you want predictable fixture ordering.

### 5. Require the Type Early

Ensure the type is loaded before ActiveRecord. In `config/application.rb`:

```ruby
require_relative "../lib/rails_ext/active_record_uuid_type"
```

### 6. Configure Database

**SQLite (config/database.yml):**
```yaml
development:
  adapter: sqlite3
  database: storage/development.sqlite3

test:
  adapter: sqlite3
  database: storage/test.sqlite3
```

**PostgreSQL (config/database.yml):**
```yaml
production:
  adapter: postgresql
  database: myapp_production
  # UUIDs work out of the box with native uuid type
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `lib/rails_ext/active_record_uuid_type.rb` | Core UUID types with base36 encoding (SQLite + PostgreSQL) |
| `config/initializers/uuid_primary_keys.rb` | Database adapters and auto-default generation |
| `config/application.rb` | Generator configuration |
| `test/test_helper.rb` | Fixture UUID generation |
| `db/schema.rb` | Schema showing UUID columns |
