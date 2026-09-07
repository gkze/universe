# Keep complete SHA-256 literals readable in the release manifest.
FILENAME == "./releases.lua" &&
  /^[[:space:]]*(sha256|signer_sha256) = "[[:xdigit:]]{64}",$/ { next }
length($0) > 80 {
  printf "%s:%d: line exceeds 80 columns (%d)\n", FILENAME, FNR, length($0)
  failed = 1
} END { exit failed }
