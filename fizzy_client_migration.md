# Fizzy Client Migration Notes

This document captures migration-specific guidance that is intentionally separate from `fizzy_client.prd.md`.

## Attachment migration strategy

For each source attachment:
1. download the file
2. compute metadata and checksum
3. create a Fizzy direct upload record
4. upload bytes to the returned storage URL
5. embed an ActionText attachment tag into the card/comment HTML

This preserves attachments as real Fizzy attachments instead of plain external links.

## Suggested helper flow

Useful client helpers for migration scripts:
- `create_direct_upload`
- `upload_direct_file`
- `build_rich_text_attachment`
- `upload_attachment_and_build_tag`
- `append_attachments_to_html`

## User matching strategy

User matching is a migration concern, not a core client concern.

Recommended importer strategy:
1. exact email match
2. fallback to exact name match
3. if no match is found, leave the card unassigned and record a warning externally

## Assignment migration guidance

If source-system users already exist in Fizzy:
- resolve assignees primarily by exact email match
- fallback to exact name match if email mapping fails
- if no match is found, leave the card unassigned and record a warning externally

## Authorship guidance

Original authorship does not need to be preserved exactly.

Recommended approach:
- create cards/comments with the importing bearer-token identity
- if desired, importer may add attribution text into the rich text body, e.g.:

```html
<p><em>Imported from another system. Original author: Jane Doe</em></p>
```
