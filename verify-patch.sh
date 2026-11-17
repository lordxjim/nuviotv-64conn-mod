#!/usr/bin/env bash
# verify-patch.sh — verifies that the 64-connection patch is fully and consistently
# applied to a NuvioTV checkout. Run from the NuvioTV repository root:
#
#   bash verify-patch.sh
#
# Used by .github/workflows/patch-and-build.yml right after `git am`, and usable
# locally after manual application. Exits non-zero if any invariant is broken.
set -u

fail=0

ok()   { printf '  [ok]    %s\n' "$1"; }
bad()  { printf '  [FAIL]  %s (%s)\n' "$1" "$2"; fail=1; }

# present <name> <extended-regex> <file>
present() {
  if grep -qE "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1" "$3"; fi
}

# absent <name> <extended-regex> <file>
absent() {
  if grep -qE "$2" "$3" 2>/dev/null; then bad "$1" "$3"; else ok "$1"; fi
}

DS="app/src/main/java/com/nuvio/tv/data/local/PlayerSettingsDataStore.kt"
UI="app/src/main/java/com/nuvio/tv/ui/screens/settings/PlaybackBufferNetworkSettings.kt"
MB="app/src/main/java/com/nuvio/tv/ui/screens/settings/MemoryBudget.kt"
MF="app/src/main/java/com/nuvio/tv/ui/screens/player/PlayerMediaSourceFactory.kt"
PD="app/src/main/java/com/nuvio/tv/ui/screens/player/ParallelRangeDataSource.kt"
PN="app/src/main/java/com/nuvio/tv/ui/screens/player/PlayerPlaybackNetworking.kt"
PH="app/src/main/java/com/nuvio/tv/ui/screens/player/NuvioExoPlayerPerformanceHelper.kt"
ST="app/src/main/res/values/strings.xml"
YT="app/src/main/java/com/nuvio/tv/data/trailer/InAppYouTubeExtractor.kt"

echo "== Domain 1: parallel connection config chain =="
present "MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY = 64 declared" \
  'const val MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY = 64' "$DS"
present "UI slider max references the constant" \
  'PlayerSettings\.MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY' "$UI"
absent "no literal-16 native clamp left in DataStore" \
  'isNativeMemory\) 16 else' "$DS"
# The constant must be referenced 3 times in DataStore (read + 2 write clamps)
n=$(grep -c 'MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY' "$DS" 2>/dev/null || echo 0)
if [ "$n" -ge 4 ]; then ok "constant referenced by all DataStore clamps ($n occurrences)"; else bad "constant referenced by all DataStore clamps (found $n, need >=4: 1 decl + 3 clamps)" "$DS"; fi
present "connection count subtitle carries rate-limit caution" \
  'may\s+trigger rate limiting on strict servers' "$ST"

echo "== Domain 2: prefetch window + memory guard =="
present "depth floor lowered to connections + 1" \
  'byConnections = connections \+ 1' "$MB"
present "safeChunkMbForConnections helper declared" \
  'fun safeChunkMbForConnections' "$MB"
present "engine-side chunk guard wired in factory" \
  'safeChunkMbForConnections\(' "$MF"
present "guard logs when it clamps" \
  'exceeds native budget for' "$MF"
present "UI perf-mode chunk filter mirrors the guard" \
  'safeChunkMbForConnections\(' "$UI"
present "429 fuse: depth halving entry point intact" \
  'beginRateLimitEpisode' "$PD"
present "429 fuse: hard wait cap 15s intact" \
  'RATE_LIMIT_WAIT_HARD_CAP_MS = 15_000L' "$PD"
present "429 fuse: Retry-After parsing intact" \
  'parseHeaderMs' "$PD"
present "warm session TTL 45s intact" \
  'RETAINED_SESSION_TTL_MS = 45_000L' "$PD"
present "eviction touch guard intact" \
  'EVICTION_TOUCH_GUARD_MS' "$PD"

echo "== Domain 3: thread pool & connection capacity =="
present "shared executor core 80 / max 160" \
  '80, 160, 60L, TimeUnit\.SECONDS' "$PD"
present "connection pool idle cap 128" \
  'NUVIO_SHARED_POOL_MAX_IDLE = 128' "$PH"
n=$(grep -c 'maxRequests = 128' "$PN" 2>/dev/null || echo 0)
if [ "$n" -eq 2 ]; then ok "both playback dispatchers at 128 ($n/2)"; else bad "both playback dispatchers at 128 (found $n/2)" "$PN"; fi

echo "== Domain 4: chunk retry budget =="
present "chunk retry budget 4 attempts" \
  'CHUNK_RETRY_BUDGET = 4' "$PD"
present "retry jitter constant present" \
  'CHUNK_RETRY_JITTER_MS = 30L' "$PD"
present "retry loop uses the budget constant" \
  'for \(attempt in 0 until CHUNK_RETRY_BUDGET\)' "$PD"
present "rate-limit backoff budget untouched (3 rounds)" \
  'RATE_LIMIT_MAX_BACKOFF_RETRIES = 3' "$PD"

echo "== Domain 5: User-Agent strategy =="
present "playback UA is honest player identity" \
  'NuvioTV/" \+ com\.nuvio\.tv\.BuildConfig\.VERSION_NAME' "$MF"
present "playback UA carries engine version" \
  'MediaLibraryInfo\.VERSION' "$MF"
present "scraping chain keeps browser UA (YouTube extractor)" \
  'Mozilla/5\.0' "$YT"

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: all patch invariants verified"
  exit 0
else
  echo "RESULT: patch invariants BROKEN — do not build"
  exit 1
fi
