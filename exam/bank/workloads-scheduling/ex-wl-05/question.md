Solve this question on: `cka-use-context ex-wl-05`

A search index is split into 4 shards, numbered `0` to `3`. In namespace
`batch-shards` the ConfigMap `shard-map` maps each shard number to a region:
key `shard-<number>`, for example `shard-2`.

Create a Job named `shard-indexer` in namespace `batch-shards` that:

1. Runs exactly one successful Pod per shard number `0`, `1`, `2` and `3`, so
   that each Pod knows its shard number from the Job itself (use the Job's
   completion index; do not create one Job per shard).
2. Runs at most `2` Pods at the same time.
3. Retries each shard at most once on failure. Failures of one shard must not
   use up the retries of the other shards.
4. Uses one container named `indexer` with image `busybox:1.36`. The container
   reads the region of its shard from `shard-map` and prints exactly one line:
   `indexed shard <number>: <region>` (for example
   `indexed shard 2: us-east`), then exits successfully.

The Job must complete.
