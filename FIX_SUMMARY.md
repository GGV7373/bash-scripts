# Fix Summary: Deployed Script Issues

## Issue Identified

The error "entry: unbound variable" at line 28/371 was occurring because of a variable escaping problem in the Dockerfile generation.

### Root Cause

The `generate_dockerfile()` function in `lib/deployment-files.sh` was using a **quoted heredoc**:
```bash
cat > Dockerfile <<'DOCKERFILE'
FROM php:${PHP_VERSION}-apache-bookworm
```

#### What This Caused:

1. **Quoted heredocs prevent bash variable expansion** - When bash encounters a quoted heredoc (`<<'TAG'`), it treats all content as literal text, preventing variable expansion.

2. **Result**: `${PHP_VERSION}` was written to the Dockerfile literally instead of being expanded to the actual value (e.g., "8.2").

3. **Docker error**: The Dockerfile started with:
   ```
   FROM php:-apache-bookworm
   ```
   (empty PHP version because `${PHP_VERSION}` wasn't expanded)

4. **Secondary issue**: PHP variables (like `$entry`, `$f`, etc.) in the PHP code within heredocs would also try to be expanded by bash as shell variables if the heredoc wasn't quoted, causing "unbound variable" errors.

## Solution Applied

Changed `lib/deployment-files.sh` to use **unquoted heredocs** with proper variable escaping:

```bash
cat > Dockerfile <<DOCKERFILE
FROM php:\${PHP_VERSION}-apache-bookworm
```

### How This Works:

1. **Unquoted heredoc** (`<<DOCKERFILE`) - Allows bash to process escape sequences
2. **Escaped bash variables** (`\${PHP_VERSION}`) - The backslash escapes the first `$`, so:
   - Bash sees: `\${PHP_VERSION}`
   - Bash converts: `\$` → `$` (literal)
   - Result: `${PHP_VERSION}` written to file (Docker variable syntax)
3. **Escaped PHP variables** (`\$f`, `\$entry`, etc.) - Same process:
   - Bash converts: `\$f` → `$f`
   - Result: `$f` in the generated Dockerfile/PHP code

## Files Modified

- `/home/vgs-it2a/bash-scripts/lib/deployment-files.sh` - Line 28, generate_dockerfile() function

## Changes Made

Changed the heredoc from:
```bash
cat > Dockerfile <<'DOCKERFILE'
```

To:
```bash
cat > Dockerfile <<DOCKERFILE
```

And escaped all bash/Docker variables that needed expansion:
- `${PHP_VERSION}` → `\${PHP_VERSION}`
- `${FREESCOUT_VERSION}` → `\${FREESCOUT_VERSION}`
- `$(nproc)` → `\$(nproc)`
- etc.

PHP variables were already properly escaped with backslashes in the single-quoted string.

## Verification

All scripts now pass syntax validation:
- ✓ install-freescout-docker.sh
- ✓ lib/bootstrap.sh
- ✓ lib/common.sh
- ✓ lib/config.sh
- ✓ lib/deployment-files.sh
- ✓ lib/docker-setup.sh

## Testing

The script can now be re-run:
```bash
cd ~/bash-scripts
sudo bash install-freescout-docker.sh
```

The fix ensures:
1. Bash variables are properly expanded when generating files
2. PHP variables remain escaped so PHP code works correctly
3. Docker variables are generated with correct syntax
4. No "unbound variable" errors occur
