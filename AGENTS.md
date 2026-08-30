# Package Repository Release Invariants

The `sitectl` core package and every `sitectl-*` plugin share one public Linux
package repository at `https://packages.libops.io/sitectl`. Preserve that
operator contract:

- one APT source and one `sitectl-archive-keyring` install core and plugins;
  never create per-plugin prefixes, sources, or keyrings;
- repository metadata must contain every published version of core and every
  plugin so an exact previous-known-good version remains directly installable;
- treat package filenames and bytes as immutable: an existing filename may be
  republished only when its bytes are identical, and changed bytes must fail
  before signing-key access or any repository write;
- rebuild APT and RPM metadata from the complete retained package set; delete a
  package object only through an explicit exclusion after replacement metadata
  no longer references it;
- retain the repository lock while reading, rebuilding, publishing, and pruning
  the shared prefix; a partial read must fail before metadata is replaced;
- keep GCS object versioning enabled as an additional recovery layer for an
  accidental object replacement or deletion.

Do not model this contract as a new shell state machine. Keep publication
mechanical and put release-policy explanations in Markdown. Validate any
publisher change with a clean install using exactly this source shape:

```bash
curl -fsSL https://packages.libops.io/sitectl/sitectl-archive-keyring.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/sitectl-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/sitectl-archive-keyring.gpg] https://packages.libops.io/sitectl ./" \
  | sudo tee /etc/apt/sources.list.d/sitectl.list >/dev/null
sudo apt update
sudo apt install sitectl <plugin packages...>
```
