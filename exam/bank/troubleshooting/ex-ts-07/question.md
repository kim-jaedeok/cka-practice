Solve this question on: `cka-use-context ex-ts-07`

In namespace `media-proc` the Deployment `thumbnailer` (1 replica, container
`worker`) never stays up. Its Pod starts, stops after a moment, and is
restarted again and again.

1. Find out why the container stops.
2. Fix the Deployment so that its Pod stays `Running` and `Ready` without
   restarts, and the container prints `frame buffer ready (80000000 bytes)`.
3. The container must keep a memory limit, and the limit must not be larger
   than `256Mi`.
4. Do not change the container image, the command, or the memory request.
