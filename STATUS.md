# Implementation Status - container-dev

**Last Updated:** 2026-06-30

## Current State: Phase 1 & 2 Complete, Debugging macOS Compatibility

### ✅ Completed

**Phase 1: Core Infrastructure**
- [x] `install.sh` - Symlink installer
- [x] `bin/container-dev` - Main command wrapper with symlink resolution
- [x] `bin/list.sh` - Container listing (rewritten for bash 3.x compatibility)
- [x] `bin/persist.sh` - Transient→persistent conversion (skeleton)
- [x] `bin/start.sh` - Complete rewrite with transient/persistent logic
- [x] `bin/stop.sh` - Persistent warnings and state cleanup
- [x] State file management at `~/.config/container-dev/state`
- [x] SSH config auto-management

**Phase 2: Auth Unification**
- [x] Auth auto-detection logic (Vertex/API/Web)
- [x] Unified `claude` profile in `profiles/claude/`
- [x] Machine-level config at `~/.config/container-dev/config`
- [x] Backward compatibility (old profiles still work)
- [x] README.md - Complete rewrite
- [x] CLAUDE.md - Architecture documentation

### 🐛 Currently Debugging (macOS Compatibility)

**Issue 1: Container list detection**
- Apple's `container` CLI doesn't support `--format` flag like Docker
- Fixed by using `container list | awk 'NR>1{print $1}'` instead
- Need to verify regex pattern matches actual container names

**Issue 2: Bash 3.x compatibility**
- macOS ships with bash 3.x (not 4.x)
- `declare -A` (associative arrays) not supported
- Fixed in `list.sh` by rewriting without associative arrays

**Issue 3: Grep patterns on BSD grep**
- BSD grep (macOS) interprets `-` in patterns differently than GNU grep
- Fixed by adding `--` to separate options from patterns

**Need from user:**
- Output of `container list` to verify column format
- Test if `container-dev list` now works after bash 3.x fix
- Test if existing `claude-transient` container is detected

### 🚧 Known Issues to Fix

1. **persist.sh** - Only has skeleton implementation, needs full container recreation logic
2. **Container name detection** - May need to adjust regex if Apple's container naming differs
3. **Port conflict detection** - Using `lsof -i :PORT` which might need adjustment

### 📋 Next Steps (When Debugging Complete)

**Phase 3: Opencode Profiles**
- [ ] Create `profiles/opencode/` - Opencode with Claude backend
- [ ] Create `profiles/opencode-local/` - Opencode with llama.cpp
- [ ] Add llama.cpp installation to Dockerfile
- [ ] Create model download helpers
- [ ] Test both profiles

**Phase 4: Pi Profiles**
- [ ] Create `profiles/pi/` - Pi with Claude backend
- [ ] Create `profiles/pi-local/` - Pi with llama.cpp

**Phase 5: Polish**
- [ ] Complete `persist.sh` implementation (container commit + recreate)
- [ ] Comprehensive testing on macOS
- [ ] Migration guide for users on old profiles

## Test Commands

```bash
# Installation
cd ~/path/to/container-dev
./install.sh

# Start transient
cd ~/some-project
container-dev start claude
ssh claude-transient

# List containers
container-dev list

# Start persistent
cd ~/important-project
container-dev start claude --persistent
ssh claude-importantproject

# Stop
container-dev stop claude-transient
```

## Key Files Modified

**New Files:**
- `install.sh`
- `bin/container-dev`
- `bin/list.sh`
- `bin/persist.sh`
- `profiles/claude/` (all files)
- `STATUS.md` (this file)

**Updated Files:**
- `bin/start.sh` (complete rewrite)
- `bin/stop.sh` (enhanced)
- `README.md` (complete rewrite)
- `CLAUDE.md` (updated architecture)

## Architecture Summary

### Container Types
- **Transient** (default): `{profile}-transient`, auto-replaced on workspace change
- **Persistent** (--persistent): `{profile}-{workspace-slug}`, never auto-replaced

### State Tracking
- File: `~/.config/container-dev/state`
- Format: `{name}|{workspace}|{port}|{type}`

### Auth Detection (Claude profiles)
1. Check for gcloud ADC → `vertex`
2. Check for ANTHROPIC_API_KEY → `api`
3. Fallback → `web` (browser OAuth)

### Profiles
- `claude` - Unified profile with auto-detected auth (replaces 3 old profiles)
- `claude-vertex`, `claude-pro-api`, `claude-pro-web` - Deprecated but still work
- Future: `opencode`, `opencode-local`, `pi`, `pi-local`

## Debug Session Context

**Current Problem:**
Testing on macOS revealed compatibility issues with:
1. `container list --format` not supported
2. bash 3.x lacking associative arrays
3. BSD grep pattern matching

**Fixes Applied:**
- Changed all `container list --format '{{.Names}}'` to `container list | awk 'NR>1{print $1}'`
- Rewrote `list.sh` without associative arrays
- Added `--` to grep patterns

**Waiting For:**
- User to test `container-dev list` after fixes
- Output of `container list` to debug why `claude-transient` not detected
- Verification that container name regex patterns work on Apple container CLI

## Plan File

Full implementation plan at: `/root/.claude/plans/this-codebase-has-three-smooth-puppy.md`
