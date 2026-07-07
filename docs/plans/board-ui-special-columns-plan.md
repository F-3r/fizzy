# Board UI special columns plan

## Goal

Change the board UI so the main board no longer renders the special Backlog/Maybe column or the Not Now column inline.

Instead:
- show normal columns and Done on the board
- move card creation into the top controls beside filters
- add a dropdown menu in the top controls with links to Backlog and Not Now
- apply the same behavior to private and public boards

Underlying behavior stays the same:
- backlog remains cards with `column_id = nil`
- Not Now remains the postponed state
- sending cards to backlog or Not Now still works
- dedicated expanded views remain the way to access those lists

## Product decisions

- Top controls should show: filters, add card, and a dropdown menu with two options: Backlog and Not Now
- Change applies to all boards, including public boards
- Show counts only if existing plumbing already makes this a simple display concern; do not add new count-calculation plumbing for this change

## Implementation plan

### 1. Add board toolbar actions beside filters

Add board-scoped actions to the controls area near the filter toggle.

Likely files:
- `app/views/filters/_settings.html.erb`
- new partial such as `app/views/boards/show/_toolbar_actions.html.erb`
- new public partial if needed, such as `app/views/public/boards/show/_toolbar_actions.html.erb`

Controls:
- Add card
  - private boards: `board_cards_path(board)`
- Dropdown menu
  - Backlog: `board_columns_stream_path(board)` / public equivalent
  - Not Now: `board_columns_not_now_path(board)` / public equivalent

Implementation notes:
- Reuse existing button/menu patterns already used in the app where possible
- Keep labels accessible even if mobile presentation becomes icon-first
- If count display is trivial from existing board associations, include counts in the dropdown labels or nearby UI; otherwise skip counts for this change

### 2. Remove inline Backlog and Not Now columns from board views

Stop rendering the special columns inside the main board column layout.

Private board file:
- `app/views/boards/show/_columns.html.erb`

Public board file:
- `app/views/public/boards/show/_columns.html.erb`

Remove inline rendering of:
- Backlog/Maybe stream column
- Not Now column

Keep rendering of:
- normal columns
- Done column
- add-column affordance where applicable

Implementation notes:
- Verify the resulting grid still lays out correctly when the center special column is removed
- Confirm drag/drop still works for normal columns and Done

### 3. Simplify collapsible column behavior

The current Stimulus controller has hardcoded special handling for the Maybe column.
That logic must be removed once the special column is no longer rendered inline.

File:
- `app/javascript/controllers/collapsible_columns_controller.js`

Required changes:
- remove `maybeColumnTarget`
- remove special desktop/mobile logic that forces Maybe open or disables its button
- make collapse/expand behavior operate only on the columns actually rendered on the page

Implementation notes:
- Verify keyboard navigation still behaves correctly
- Verify state restore from localStorage still works with the reduced column set
- Verify no controller errors occur on private or public boards

### 4. Remove the old board-level add-card placement

The board page currently renders card creation outside the filter controls and inside the special backlog area.
Those placements should be removed.

Files:
- `app/views/boards/show.html.erb`
- `app/views/boards/show/_stream.html.erb`
- `app/views/public/boards/show/_stream.html.erb` if public UI is being fully aligned
- `app/views/columns/show/_add_card_button.html.erb` if it becomes unused

Implementation notes:
- Confirm there is only one Add card entry point on the main private board UI after the change
- Public boards should not gain card-creation affordances; only align special-column access behavior there

### 5. Keep dedicated Backlog and Not Now pages intact

No model or routing changes are needed for the expanded views.

Existing private/public endpoints should remain the source of truth:
- backlog stream page
- Not Now page

Relevant files include:
- `app/controllers/boards/columns/streams_controller.rb`
- `app/controllers/public/boards/columns/streams_controller.rb`
- existing Not Now controllers/views under boards/public boards columns

Implementation notes:
- Update any button labels or page entry copy if needed for consistency with “Backlog” naming in the new UI
- Leave underlying state and movement logic unchanged

### 6. CSS and layout pass

Adjust styling so the new top controls and reduced board column layout look correct on desktop and mobile.

Likely files:
- `app/assets/stylesheets/filters.css`
- `app/assets/stylesheets/card-columns.css`

Areas to verify:
- filter toggle + Add card + dropdown alignment
- wrapping on narrow screens
- spacing between controls
- board grid after removing special inline columns
- public board layout

### 7. Tests

Update or add tests covering the new UI and preserving existing behavior.

System/integration coverage to add or update:
- private board shows Add card near filter controls
- private board shows a dropdown with Backlog and Not Now links
- private board no longer renders inline Backlog column
- private board no longer renders inline Not Now column
- Add card still works from the new location
- Backlog link opens the expanded backlog page
- Not Now link opens the expanded Not Now page
- public board no longer renders inline Backlog column
- public board no longer renders inline Not Now column
- public board exposes the special-column access affordance if intended in final UI

Likely files:
- `test/system/smoke_test.rb`
- `test/controllers/boards/columns/streams_controller_test.rb`
- `test/controllers/public/boards/columns/streams_controller_test.rb`
- Not Now controller tests for private/public boards if present
- board/public board integration tests as needed

Implementation notes:
- Keep existing dedicated-page tests intact
- Prefer assertions on visible UI and navigation over implementation details

### 8. Docs and release notes

Update docs to reflect the board UI change.

Areas to cover:
- user-facing docs that describe board navigation or card creation
- any developer docs that describe the board layout and special columns
- release notes/changelog entry if the repo uses one

Documentation points to capture:
- Backlog and Not Now are no longer shown inline on the board
- both are accessed from the top controls
- Add card moved beside filters
- backlog still maps to cards without a column
- no data model change accompanies this release

Likely places to inspect/update:
- `README.md`
- `docs/` files related to development or product behavior
- any release-notes/changelog location used by the team

## Open implementation checks

- Confirm whether existing UI plumbing makes count display trivial for Backlog and Not Now
- Decide the exact dropdown component to reuse so behavior is consistent with the rest of the app
- Confirm the final public-board affordance, since public boards cannot expose Add card but should align on special-column access
- Verify whether `app/views/boards/show/_stream.html.erb` and `app/views/public/boards/show/_stream.html.erb` become fully unused after the change

## Handover notes for implementation

- Update `app/javascript/controllers/collapsible_columns_controller.js` together with removing inline Backlog/Maybe rendering. The controller currently assumes that special column exists in the DOM.
- Reuse existing expanded pages and routes for Backlog and Not Now. Do not introduce new routes or duplicate pages for this UI change.
- Keep this change UI-only unless a blocker is discovered. Avoid schema changes, board flags, or new card-state concepts.
- For counts, only use existing trivial associations/scopes such as `board.cards.awaiting_triage.count` and `board.cards.postponed.count` if they fit cleanly. Skip counts rather than adding new plumbing.
- Public boards should align on special-column access, but must not gain card-creation controls.
- After implementation, verify whether these become dead code and can be safely removed:
  - `app/views/boards/show/_stream.html.erb`
  - `app/views/public/boards/show/_stream.html.erb`
  - `app/views/columns/show/_add_card_button.html.erb`
- Manually verify these behaviors in addition to automated tests:
  - private board loads without Stimulus/controller errors
  - public board loads without Stimulus/controller errors
  - Add card still creates a draft from the new location
  - Backlog opens from the new menu
  - Not Now opens from the new menu
  - normal columns still collapse/expand correctly
  - keyboard navigation still works on board pages
  - drag/drop between visible columns still works
- Watch for CSS/layout regressions caused by removing the center special column, especially on mobile, on boards with many columns, and on public board layouts.
- Avoid widening scope into unrelated hardcoded “Maybe?” strings in notifications, exports, prompts, or card movement copy unless the changed UI directly depends on them.
