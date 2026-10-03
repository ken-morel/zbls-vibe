# zbls-vibe

**zbls-vibe** (Zig Build Language Server) is a lightweight, companion Language Server Protocol (LSP) server for Zig.

While [zls](https://github.com/zigtools/zls) excels at fast local AST completions, hover, and document symbols, it does not execute `build.zig`, full comptime type reflection, or cross-package compile checks. `zbls-vibe` runs alongside `zls` by executing:

```bash
zig build -fincremental --watch --color off
```

in the background. Every time Zig notices a file change and rebuilds incrementally, `zbls-vibe` parses compiler errors, warnings, notes, and reference traces, publishing diagnostics directly to your editor in near real-time. When errors are resolved, diagnostics are immediately cleared.

---

## Features

- **Near Real-time Incremental Diagnostics**: Leverages Zig 0.17's native `-fincremental --watch` compilation.
- **Companion to ZLS**: Designed to run as a secondary language server without conflicting with `zls`.
- **Precise Range Underlines**: Correctly parses caret spans (`^~~~` and `~~~~^~~~`).
- **Related Information**: Zig compiler notes (such as `struct declared here` or comptime `called at comptime here`) and `referenced by:` traces are attached as LSP `relatedInformation`.
- **Zero External Dependencies**: Built with 100% native Zig standard library.
- **Configurable**: Customize Zig binary path, build arguments, and debounce intervals via LSP settings or CLI flags.

---

## Installation & Building

Clone and build with Zig 0.17+:

```bash
git clone https://github.com/ken-morel/zbls-vibe.git
cd zbls-vibe
zig build -Doptimize=ReleaseFast
```

The compiled binary will be placed at `./zig-out/bin/zbls_vibe`. Copy or symlink it into your `PATH`:

```bash
cp ./zig-out/bin/zbls_vibe ~/.local/bin/zbls-vibe
```

---

## Editor Configuration

### Helix Editor

Helix supports multiple language servers natively. Add `zbls-vibe` alongside `zls` in your `languages.toml` (typically `~/.config/helix/languages.toml` or `.helix/languages.toml`):

```toml
[language-server.zls]
command = "zls"

[language-server.zbls]
command = "zbls-vibe"

# Optional configuration:
[language-server.zbls.config]
# zigPath = "zig"
# buildArgs = ["build", "-fincremental", "--watch", "--color", "off"]
# extraArgs = []
# debounceMs = 100

[[language]]
name = "zig"
language-servers = [ "zls", "zbls" ]
```

When you edit Zig files in Helix:
- `zls` provides syntax checking, autocompletion, hover documentation, and jump-to-definition.
- `zbls` provides full project-wide compiler diagnostics, comptime type errors, and build step verification directly in your gutter and statusline.

---

### Neovim

Using `nvim-lspconfig`:

```lua
local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.zbls then
  configs.zbls = {
    default_config = {
      cmd = { 'zbls-vibe' },
      filetypes = { 'zig' },
      root_dir = lspconfig.util.root_pattern('build.zig', '.git'),
      settings = {},
    },
  }
end

lspconfig.zbls.setup{}
lspconfig.zls.setup{}
```

---

### VS Code

Using the generic LSP client configuration or settings:

```json
{
  "zbls.zigPath": "zig",
  "zbls.buildArgs": ["build", "-fincremental", "--watch", "--color", "off"],
  "zbls.debounceMs": 100
}
```

---

## CLI Usage

```
zbls-vibe: Companion LSP server running `zig build -fincremental --watch`

Usage:
  zbls-vibe [options] [-- <extra zig build args...>]

Options:
  -h, --help       Show this help message
  -v, --version    Show version information
  --zig <path>     Path to zig executable (default: "zig")
```

---

## Running Tests

Run the test suite:

```bash
zig build test
```

---

## License

MIT / Apache-2.0
