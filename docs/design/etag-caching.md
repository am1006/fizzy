# ETag Caching in Fizzy

This document explains how Fizzy uses HTTP ETag caching to reduce server load and improve response times. ETags provide a "conditional GET" mechanism where the server can return a lightweight 304 Not Modified response instead of re-rendering the entire page.

## Overview

### What is ETag Caching?

ETags (Entity Tags) are HTTP response headers that act as fingerprints of response content. Here is the flow:

1. **First request**: Server responds with content and an `ETag` header (a hash of the data)
2. **Subsequent requests**: Browser sends `If-None-Match` header with the cached ETag
3. **Server checks**: If the computed ETag matches, responds with `304 Not Modified` (no body)
4. **Browser uses cache**: Displays cached content without re-downloading

This is particularly valuable for Turbo Frame requests and lazy-loaded content, where many small requests can benefit from caching.

### Why Fizzy Uses ETags

Fizzy uses ETags extensively for:

- **Lazy-loaded menus and dropdowns**: Expensive queries deferred until needed, cached after first load
- **Activity timelines**: Event data that rarely changes during a session
- **User-specific toggles**: Watch/pin status that changes infrequently
- **Board columns**: Card listings that update only when cards move

## Architecture

### Global ETag Components

Fizzy builds ETags from multiple sources layered together in `ApplicationController`:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include CurrentTimezone
  # ... other concerns

  etag { "v1" }                    # Version string for cache busting
  stale_when_importmap_changes     # JavaScript changes invalidate cache
end
```

Each `etag { ... }` block adds a component to the final ETag calculation. Rails combines these with any action-specific ETag data.

### Concern-Based ETag Composition

Each concern adds relevant context to the ETag:

**Authentication** (`app/controllers/concerns/authentication.rb`):
```ruby
included do
  etag { Current.identity.id if authenticated? }
end
```

This ensures different users get different ETags, preventing one user from seeing another's cached content.

**CurrentTimezone** (`app/controllers/concerns/current_timezone.rb`):
```ruby
included do
  etag { timezone_from_cookie }
end
```

Time-formatted content varies by timezone. Including the timezone cookie in the ETag means users in different timezones get correctly formatted dates.

### Final ETag Calculation

The complete ETag is computed from:

1. Application version (`"v1"`) - allows global cache busting on deployments
2. Importmap digest - JavaScript changes invalidate cached HTML
3. User identity ID - user-specific content isolation
4. Timezone cookie - locale-appropriate time formatting
5. Action-specific objects - the actual data being rendered

## Implementation Patterns

### Pattern 1: Simple Object ETag with `fresh_when`

The simplest pattern passes one or more objects to `fresh_when`. Rails uses each object's `cache_key_with_version` (which includes `updated_at`):

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/boards/columns_controller.rb
class Boards::ColumnsController < ApplicationController
  def index
    @columns = @board.columns.sorted
    fresh_when etag: @columns
  end

  def show
    set_page_and_extract_portion_from @column.cards.active.latest.with_golden_first.preloaded
    fresh_when etag: @page.records
  end
end
```

**Key insight**: Passing an ActiveRecord relation computes the ETag from all records in the collection. Any addition, removal, or update invalidates the cache.

### Pattern 2: Multiple Object Arrays

For views that depend on multiple independent datasets:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/my/menus_controller.rb
class My::MenusController < ApplicationController
  def show
    @filters = Current.user.filters.all
    @boards = Current.user.boards.ordered_by_recently_accessed
    @tags = Current.account.tags.all.alphabetically
    @users = Current.account.users.active.alphabetically
    @accounts = Current.identity.accounts

    fresh_when etag: [ @filters, @boards, @tags, @users, @accounts ]
  end
end
```

The ETag changes if any of these collections change. This is ideal for menus and sidebars that aggregate data from multiple sources.

### Pattern 3: Composite Objects with Related Data

When caching depends on both a primary object and its associations:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/my/pins_controller.rb
class My::PinsController < ApplicationController
  def index
    @pins = Current.user.pins.includes(:card).ordered.limit(20)
    fresh_when etag: [ @pins, @pins.collect(&:card) ]
  end
end
```

This ensures the ETag changes when either the pins or their associated cards change.

### Pattern 4: Custom Cache Key Objects

For complex views, create a dedicated class with a `cache_key` method:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/models/user/day_timeline.rb
class User::DayTimeline
  def cache_key
    ActiveSupport::Cache.expand_cache_key [ user, filter, day.to_date, events ], "day-timeline"
  end
end

# /Users/leo/zDev/GitHub/fizzy/app/controllers/events_controller.rb
class EventsController < ApplicationController
  def index
    fresh_when @day_timeline
  end
end
```

The `cache_key` method explicitly defines what data affects the cache. This provides fine-grained control over invalidation.

**Another example:**

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/models/user/filtering.rb
class User::Filtering
  def cache_key
    ActiveSupport::Cache.expand_cache_key(
      [ user, filter, expanded?, boards, tags, users, filters ],
      "user-filtering"
    )
  end
end
```

### Pattern 5: Fallback Values for Optional Data

When caching depends on data that may not exist:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/cards/watches_controller.rb
class Cards::WatchesController < ApplicationController
  def show
    fresh_when etag: @card.watch_for(Current.user) || "none"
  end
end

# /Users/leo/zDev/GitHub/fizzy/app/controllers/cards/pins_controller.rb
class Cards::PinsController < ApplicationController
  def show
    fresh_when etag: @card.pin_for(Current.user) || "none"
  end
end
```

The string `"none"` provides a stable ETag when the user has not pinned/watched the card. When they do pin/watch, the actual record's cache key is used.

### Pattern 6: Using `stale?` for Conditional Rendering

When you need to perform additional work after the ETag check:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/prompts/cards_controller.rb
class Prompts::CardsController < ApplicationController
  def index
    @cards = if filter_param.present?
      prepending_exact_matches_by_id(search_cards)
    else
      published_cards.latest
    end

    if stale? etag: @cards
      render layout: false
    end
  end
end
```

`stale?` returns `true` if the cache is invalid (and we should render), or `false` if we've already sent a 304 response. This pattern is useful when you need to customize the render call.

### Pattern 7: Cache Control with `stale?`

For public or semi-public content, combine ETag validation with cache control headers:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/users/avatars_controller.rb
class Users::AvatarsController < ApplicationController
  def show
    if @user.avatar.attached?
      redirect_to rails_blob_url(@user.avatar_thumbnail, disposition: "inline")
    elsif stale? @user, cache_control: cache_control
      render_initials
    end
  end

  private
    def cache_control
      if @user == Current.user
        {}  # No caching for current user (they might update their name)
      else
        { max_age: 30.minutes, stale_while_revalidate: 1.week }
      end
    end
end
```

This pattern shows intelligent cache control: the current user's avatar regenerates on every request (no caching), while other users' avatars are cached for 30 minutes with stale-while-revalidate semantics.

### Pattern 8: Whole Collection for Accurate Invalidation

Sometimes you need to base the ETag on a broader dataset than what you display:

```ruby
# /Users/leo/zDev/GitHub/fizzy/app/controllers/notifications/trays_controller.rb
class Notifications::TraysController < ApplicationController
  def show
    @notifications = Current.user.notifications.preloaded.unread.ordered.limit(100)

    # Invalidate on the whole set instead of the unread set since the max updated at
    # in the unread set can stay the same when reading old notifications.
    fresh_when Current.user.notifications
  end
end
```

The comment explains the reasoning: marking a notification as read changes the full set but might not change the "max updated_at" of unread notifications. Using the full collection ensures proper cache invalidation.

## Composing Multiple ETag Sources

The ETag for any request is built from:

```
ApplicationController base etag ("v1")
  + importmap digest
  + Authentication etag (user identity)
  + CurrentTimezone etag (timezone cookie)
  + Action-specific etag (from fresh_when)
```

This composition happens automatically. Each `etag { }` block contributes to the final hash.

## Invalidation Through Touch Chains

Fizzy uses `touch: true` on associations to propagate changes:

```ruby
class Comment < ApplicationRecord
  belongs_to :card, touch: true
end
```

When a comment is created or updated, the card's `updated_at` is automatically bumped, which invalidates any ETag that includes the card.

## Testing ETag Behavior

Fizzy tests ETag caching explicitly:

```ruby
# /Users/leo/zDev/GitHub/fizzy/test/controllers/my/menus_controller_test.rb
class My::MenusControllerTest < ActionDispatch::IntegrationTest
  test "etag invalidates when filters change" do
    get my_menu_path
    assert_response :success
    etag = response.headers["ETag"]

    @user.filters.create!(
      params_digest: Filter.digest_params({ indexed_by: :all, sorted_by: :newest }),
      fields: { indexed_by: :all, sorted_by: :newest }
    )

    get my_menu_path, headers: { "If-None-Match" => etag }
    assert_response :success  # 200, not 304, because data changed
  end

  test "etag returns not modified when nothing changes" do
    get my_menu_path
    assert_response :success
    etag = response.headers["ETag"]

    get my_menu_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified  # 304
  end
end
```

**Testing pattern:**
1. Make a request and capture the ETag
2. Modify the underlying data
3. Make a request with `If-None-Match` header
4. Assert `200 OK` (cache invalidated) or `304 Not Modified` (cache valid)

Testing timezone influence on ETags:

```ruby
# /Users/leo/zDev/GitHub/fizzy/test/controllers/concerns/current_timezone_test.rb
class CurrentTimezoneTest < ActionDispatch::IntegrationTest
  test "includes the timezone cookie in the ETag" do
    cookies[:timezone] = "America/New_York"
    get user_avatar_path(users(:kevin))
    etag = response.headers.fetch("ETag")

    get user_avatar_path(users(:kevin)), headers: { "If-None-Match" => etag }
    assert_equal 304, response.status

    cookies[:timezone] = "America/Los_Angeles"
    get user_avatar_path(users(:kevin)), headers: { "If-None-Match" => etag }
    assert_response :success  # Different timezone = different ETag
  end
end
```

## Important Considerations

### Do Not Use `fresh_when` with Forms

CSRF tokens are embedded in forms and become stale. Using `fresh_when` on pages with forms can cause 422 Unprocessable Entity errors when users submit from cached pages:

```ruby
# BAD - form will have stale CSRF token
def edit
  @card = Card.find(params[:id])
  fresh_when @card  # Don't do this!
end

# GOOD - no HTTP caching on form pages
def edit
  @card = Card.find(params[:id])
end
```

### JavaScript Changes and Importmaps

The `stale_when_importmap_changes` call in `ApplicationController` ensures that when JavaScript assets change (via importmap updates), cached HTML pages are invalidated. This prevents scenarios where the browser serves cached HTML that references outdated JavaScript.

### User-Specific Content

Always include user identity in ETags when content varies by user. The `Authentication` concern handles this automatically with:

```ruby
etag { Current.identity.id if authenticated? }
```

## Performance Benefits

ETag caching in Fizzy provides several performance wins:

1. **Reduced rendering**: 304 responses skip view rendering entirely
2. **Reduced bandwidth**: No response body sent for cache hits
3. **Lower database load**: `fresh_when` can short-circuit before expensive queries in some patterns
4. **Better perceived performance**: Instant updates for unchanged content

The pattern is especially effective for:
- Turbo Frame requests (many small, cacheable fragments)
- Lazy-loaded content (menus, dropdowns loaded on hover/click)
- Activity feeds and timelines (data that changes infrequently)

## Related Systems

- **Fragment Caching**: See `/Users/leo/zDev/GitHub/fizzy/docs/guide/caching.md` for view-level fragment caching patterns
- **Touch Chains**: Association `touch: true` options propagate changes for cache invalidation
- **Turbo Frames**: Lazy-loaded frames benefit heavily from ETag caching

## Implementation Checklist

When adding ETag caching to a new action:

1. Identify all data that affects the rendered output
2. Choose the appropriate pattern (simple object, array, custom cache_key)
3. Ensure associated data changes propagate via `touch: true`
4. Add tests verifying cache invalidation on data changes
5. Verify no forms exist in the cached response
6. Consider if timezone or user identity affects the output (handled globally in Fizzy)
