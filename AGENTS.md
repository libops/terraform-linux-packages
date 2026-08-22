# Package Repository Release Invariants

The `sitectl` core package and every `sitectl-*` plugin share one public Linux
package repository at `https://packages.libops.io/sitectl`. Preserve that
operator contract:

- one APT source and one `sitectl-archive-keyring` install core and plugins;
  never create per-plugin prefixes, sources, or keyrings;
- repository metadata must contain the latest release of core and every
  published plugin, even when only one package is being released;
- keep only the latest live package version for each package and architecture;
  GitHub Releases are the artifact archive and rollback source;
- use stable source-object names, rebuild APT and RPM metadata from the complete
  current set, and delete objects absent from that rebuilt repository so old
  versions cannot accumulate in GCS;
- retain the repository lock while reading, rebuilding, publishing, and pruning
  the shared prefix; a partial read must fail before metadata is replaced;
- keep GCS object versioning disabled and retain the short lifecycle cleanup for
  any legacy noncurrent generations.

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
