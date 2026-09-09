# Persisted service streaming review

The persisted backend now forwards assistant and reasoning events as typed
`stream_append` and `stream_reset` deltas, carrying the message identity, run
attempt, channel, and current record revision. Stream events retain FIFO order
while credit is withheld; complete entity replacements may still coalesce.
Events exceeding the DTO text bound invalidate the watch through the existing
overflow/resnapshot path.

The concurrent persisted-backend changes provide body-specific revisions for
node upserts, bounded SQL projections, scoped detail reads, and transcript
keyset pagination. Those changes were retained.

Added a persisted-backend regression that withholds credit across text appends,
reasoning, a reset, and another append; each resulting event passes the actual
client `Codec.event/3`. It also verifies the oversized event overflow path.

Validation:

```
mix test apps/swarm_code_daemon/test/swarm_code/daemon/service/persisted_backend_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/daemon_codec_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/daemon_watch_codec_test.exs
```

Result: 14 daemon tests and 19 CLI codec tests passed. No native or Repo files
were edited by this review pass.
