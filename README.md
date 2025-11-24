# metadata-backup

A utility for backing up and restoring file metadata

## Background

This tool was born from a painful experience where a recursive chmod/chown command gone wrong rendered a system unbootable. The only recourse at the time was restoring an entire backup just to fix metadata - a wasteful solution to what should have been a simple problem. This tool aims to prevent such headaches by providing a way to backup, diff and restore just file/directory metadata, to a mirrored file hierarchy of empty files.

## Description

This script creates metadata-only backups of files and directories, preserving:
- Permissions (including special bits like setuid, setgid, sticky)
- Ownership (user and group)
- Timestamps
- Directory structure

The backup contains empty files with the same metadata as the originals, making it space-efficient for metadata recovery scenarios.

### Symlinks

Symbolic links are intentionally ignored during backup and restore operations. This is because symlink metadata is not meaningful for backup purposes - the permissions and ownership of a symlink are ignored by the system in favor of the target file's metadata. When restoring metadata, we focus on the actual target files rather than the symlinks pointing to them.

## Installation

1. Ensure you have the GNU core utilities installed:
   - On macOS: `brew install coreutils` (or use Nix's `coreutils-prefixed` package)
   - On Linux: These should be available by default

2. Copy the `metadata` script to a directory in your PATH

## Usage

```bash
metadata [OPTIONS] COMMAND [ARGS]
```

### Options

- `-h, --help` - Show help message and exit
- `-v, --version` - Show version information and exit

### Commands

- `backup SOURCE [DEST]` - Create a metadata-only backup of SOURCE in DEST
  - If DEST is omitted, uses `SOURCE.metadata_%timestamp`
- `restore BACKUP DEST` - Restore metadata from BACKUP to DEST
- `diff DIR1 DIR2` - Compare metadata between two directories
- `test` - Run the test suite

### Environment Variables

- `TIMESTAMP` - Format string for %timestamp replacement (default: %Y%m%d%H%M%S)
- `EXCLUDES` - Space-separated list of paths to exclude (default: `"/tmp /proc /dev /sys /private .git node_modules __pycache__ .DS_Store"`)
- `DEBUG` - Set to `1|t?(rue)|on|y?(es)|enable?(d)` to enable debug output

### Default Exclusions

The following paths are excluded by default (override with `EXCLUDES` env var):
```
/tmp
/proc
/dev
/sys
/private
.git
node_modules
__pycache__
.DS_Store
```

### Timestamp Format

The DEST path can include date format strings that will be replaced:
- Use `%timestamp` to insert a timestamp (default: `%Y%m%d%H%M%S`)
  - Override with `TIMESTAMP` env var
- Use any date format string (see `man date`):
  - `%Y` (year), `%m` (month), `%d` (day)
  - `%H` (hour), `%M` (minute), `%S` (second)

### Examples

Create a metadata backup with default timestamp:

```bash
metadata backup ~/documents
# Creates: ~/documents.metadata_20250121094725
```

Create a backup with custom timestamp format:

```bash
TIMESTAMP=%Y-%m-%d metadata backup ~/documents
# Creates: ~/documents.metadata_2025-01-21
```

Use date format directly in path:

```bash
metadata backup ~/documents ~/backups/%Y/%m/%d/docs.metadata
# Creates: ~/backups/2025/01/21/docs.metadata
```

Exclude specific directories:

```bash
EXCLUDES="node_modules target .git" metadata backup ~/projects
```

Restore metadata from backup:

```bash
metadata restore ~/documents.metadata ~/documents.restored
```

Compare metadata between directories:

```bash
metadata diff ~/documents ~/documents.restored
```

## Notes

- Running with root privileges is required to preserve special permissions
- The script uses GNU versions of core utilities (gstat, gfind, etc.)
- While designed to work on both macOS and Linux, current testing has only been performed on macOS. Linux support is planned but not yet verified.

## Development

The script includes a test suite that can be run with:

```bash
metadata test
```

Debug output can be enabled by setting the DEBUG environment variable:

```bash
DEBUG=1 metadata test
