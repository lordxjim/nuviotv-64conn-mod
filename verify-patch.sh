#!/usr/bin/env bash
# verify-patch.sh — verifies that the 256-connection patch (64+256 combined,
# based on pristine upstream) is fully and consistently applied to a NuvioTV
# checkout. Run from the NuvioTV repository root:
#
#   bash verify-patch.sh
#
# Validates the FINAL tree state (upstream + nuviotv-256conn.patch). Used by
# .github/workflows/patch-and-build.yml right after `git am`, and usable
# locally after manual application. Exits non-zero if any invariant is broken.
set -u

fail=0
pass=0

ok()   { printf '  [ok]    %s\n' "$1"; pass=$((pass + 1)); }
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
TS="app/src/test/java/com/nuvio/tv/ui/screens/settings/MemoryBudgetParallel256Test.kt"
TS64="app/src/test/java/com/nuvio/tv/ui/screens/settings/MemoryBudgetNativeChunkBudgetTest.kt"
WF=".github/workflows/dev-256-build.yml"

echo "== Domain 1: parallel connection config chain (256 tier) =="
present "MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY = 256 declared" \
  'const val MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY = 256' "$DS"
# The constant must be referenced by the read clamp and both write clamps
n=$(grep -c 'MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY' "$DS" 2>/dev/null || echo 0)
if [ "$n" -ge 4 ]; then ok "constant referenced by all DataStore clamps ($n occurrences)"; else bad "constant referenced by all DataStore clamps (found $n, need >=4: 1 decl + 3 clamps)" "$DS"; fi
present "UI slider max references the constant" \
  'PlayerSettings\.MAX_PARALLEL_CONNECTION_COUNT_NATIVE_MEMORY' "$UI"
absent "no literal-16 native clamp left in DataStore" \
  'isNativeMemory\) 16 else' "$DS"
present "connection count subtitle carries rate-limit caution" \
  'rate limiting on strict servers' "$ST"

echo "== Domain 2: byte-accurate window budget =="
present "prefetchDepthBytes byte-accurate helper declared" \
  'fun prefetchDepthBytes' "$MB"
present "maxConnectionsForWindowBytes helper declared" \
  'fun maxConnectionsForWindowBytes' "$MB"
present "cancel drain bounded at 64 KB" \
  'CANCEL_DRAIN_MAX_BYTES = 64L \* 1024L' "$MB"
present "AIMD decrease gate declared" \
  'fun aimdDecreaseGate' "$MB"
present "AIMD decrease halves but never dies (floored)" \
  'coerceAtLeast\(aimdGateFloor\(connections\)\)' "$MB"
present "AIMD increase gate declared" \
  'fun aimdIncreaseGate' "$MB"
present "AIMD floor helper declared" \
  'fun aimdGateFloor' "$MB"
present "hedge stall floor 16 KB/s declared" \
  'HEDGE_STALL_FLOOR_BPS = 16L \* 1024L' "$MB"
present "64-era chunk helper retained (safeChunkMbForConnections)" \
  'fun safeChunkMbForConnections' "$MB"
present "64-era single budget source retained (nativeChunkBudgetMb)" \
  'fun nativeChunkBudgetMb' "$MB"
present "engine budgets the window via nativeChunkBudgetMb" \
  'MemoryBudget\.nativeChunkBudgetMb\(' "$MF"
present "engine sets depth via prefetchDepthBytes" \
  'MemoryBudget\.prefetchDepthBytes\(' "$MF"
present "engine caps connections via maxConnectionsForWindowBytes" \
  'MemoryBudget\.maxConnectionsForWindowBytes\(' "$MF"
present "UI mirrors the byte-budget connection cap" \
  'maxConnectionsForWindowBytes' "$UI"
present "window budget floors the streaming side at MIN_BUFFER_MB" \
  '\(minOf\(targetBufferMb, safeNativeLimitMb\) - MIN_BUFFER_MB\)' "$MB"
present "guard logs when it clamps" \
  'exceeds native budget for' "$MF"
present "UI perf-mode chunk filter mirrors the guard" \
  'safeChunkMbForConnections\(' "$UI"
absent "old full-target reserve removed (engine guard/depth)" \
  'val reserveMb = NuvioExoPlayerPerformanceHelper\.targetBufferSizeMb' "$MF"
absent "old safeNative-minus-reserve wiring removed (UI)" \
  'safeNativeMb - reserveMb' "$UI"

echo "== Domain 3: gate-based AIMD engine, fast start, adaptive hedge =="
present "ConnectionGate hard concurrency gate declared" \
  'private class ConnectionGate' "$PD"
present "429 halves the gate ceiling via AIMD decrease" \
  'MemoryBudget\.aimdDecreaseGate\(' "$PD"
present "quiet recovery raises the gate ceiling via AIMD increase" \
  'MemoryBudget\.aimdIncreaseGate\(' "$PD"
present "recoverGateIfQuiet entry point present" \
  'fun recoverGateIfQuiet\(\)' "$PD"
present "runtime cap raise via expandMax declared" \
  'fun expandMax\(connections: Int\)' "$PD"
present "settings changes expand the live gate" \
  'connectionGate\.expandMax\(connections\)' "$PD"
present "fast start threshold at 32 connections" \
  'FAST_START_MIN_CONNECTIONS = 32' "$PD"
present "fast start gate wired into re-earn logic" \
  'parallelConnections >= FAST_START_MIN_CONNECTIONS' "$PD"
present "adaptive hedge sampling (HEDGE_SAMPLE) present" \
  'HEDGE_SAMPLE' "$PD"
present "hedge stall rate 256 KB/s" \
  'HEDGE_STALL_RATE_BPS = 256L \* 1024L' "$PD"
present "engine bounds cancel drain by byte budget" \
  'CANCEL_DRAIN_MAX_BYTES' "$PD"

echo "== Domain 4: capacity, worker stack, shared connection pool =="
present "worker thread stack trimmed to 512 KB" \
  'WORKER_THREAD_STACK_BYTES = 512L \* 1024L' "$PD"
present "worker threads created with named stack size" \
  'Thread\(null, runnable, "parallel-ds-worker", WORKER_THREAD_STACK_BYTES\)' "$PD"
present "shared executor 272 core / 328 max" \
  '272, 328, 60L, TimeUnit\.SECONDS' "$PD"
present "shared connection pool idle cap 512" \
  'NUVIO_SHARED_POOL_MAX_IDLE = 512' "$PH"
present "playback builder wired to the shared pool" \
  'builder\.connectionPool\(sharedConnectionPool\)' "$PH"
present "playback clients route through shared pool optimizations" \
  'NuvioExoPlayerPerformanceHelper\.applyNetworkOptimizations\(' "$MF"
n=$(grep -c 'maxRequests = 512' "$PN" 2>/dev/null || echo 0)
if [ "$n" -eq 2 ]; then ok "both playback dispatchers at 512 ($n/2)"; else bad "both playback dispatchers at 512 (found $n/2)" "$PN"; fi

echo "== Domain 5: chunk retry budget + 429 fuse (carried from the 64 mod) =="
present "chunk retry budget 4 attempts" \
  'CHUNK_RETRY_BUDGET = 4' "$PD"
present "retry jitter constant present" \
  'CHUNK_RETRY_JITTER_MS = 30L' "$PD"
present "retry loop uses the budget constant" \
  'for \(attempt in 0 until CHUNK_RETRY_BUDGET\)' "$PD"
present "rate-limit backoff budget untouched (3 rounds)" \
  'RATE_LIMIT_MAX_BACKOFF_RETRIES = 3' "$PD"
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

echo "== Domain 6: User-Agent strategy =="
present "playback UA is honest player identity" \
  'NuvioTV/" \+ com\.nuvio\.tv\.BuildConfig\.VERSION_NAME' "$MF"
present "playback UA carries engine version" \
  'MediaLibraryInfo\.VERSION' "$MF"
present "scraping chain keeps browser UA (YouTube extractor)" \
  'Mozilla/5\.0' "$YT"

echo "== Domain 7: ledger tests + CI workflow =="
n=$(grep -c 'fun test' "$TS" 2>/dev/null || echo 0)
if [ "$n" -eq 19 ]; then ok "256 ledger test suite carries all 19 tests"; else bad "256 ledger test suite should have 19 tests (found $n)" "$TS"; fi
present "AIMD never-dies regression test present" \
  'fun testAimdDecreaseHalvesButNeverDies' "$TS"
present "cancel drain budget test present" \
  'fun testCancelDrainBudget' "$TS"
present "64-era ledger test pins the real RAM tiers" \
  'realTiers = intArrayOf\(100, 200, 500, 1000, 1600, 2000\)' "$TS64"
present "dev branch CI runs the full unit suite" \
  ':app:testFullDebugUnitTest' "$WF"
present "dev branch CI builds the APK" \
  ':app:assembleFullDebug' "$WF"

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: all $pass patch invariants verified"
  exit 0
else
  echo "RESULT: patch invariants BROKEN — do not build"
  exit 1
fi
