Solve this question on: `cka-use-context ex-wl-06`

In namespace `quorum` the StatefulSet `kv` runs `3` replicas (`kv-0`, `kv-1`,
`kv-2`) with image `nginx:1.28`. The team wants to test `nginx:1.29` on one
replica first.

1. Change the StatefulSet `kv` to the image `nginx:1.29` so that only `kv-2`
   is updated.
2. Use the StatefulSet's rolling update partition to hold back `kv-0` and
   `kv-1`.
3. `kv-2` must run `nginx:1.29` and be `Ready`.
4. `kv-0` and `kv-1` must keep running `nginx:1.28`. They must not be deleted,
   recreated or restarted at any point.

Do not change the number of replicas, and do not delete Pods by hand.
