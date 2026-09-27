# Pass 75 wire additions

body_version stays 1 (apps/swarm_code_core/lib/swarm_code/protocol/service_handshake.ex:69). Every addition is optional on the wire with a default in the DTO's wire_defaults/fields/defaults and in Codec @optional_wire_keys. No renames, no removals, no new enum values. lane and lane_at stay.

| DTO | key | field type | wire default |
| --- | --- | --- | --- |
| AgentSummary | turn | {:optional, :count} | nil |
| AgentSummary | max_turns | {:optional, :count} | nil |
| AgentSummary | summary | {:optional, {:text, 80}} | nil |
| AgentSummary | summary_rev | {:optional, :count} | nil |
| AgentSummary | last_words | {:optional, {:text, 160}} | nil |
| Question | index | :count | 0 |
| Question | header | {:optional, {:text, 64}} | nil |
| Question | total | :count | 0 |
| Question | agent_id | {:optional, :id} | nil |
| Question | requested_at | {:optional, :count} | nil |
| QuestionOption | description | {:text, 512} | "" |
| NeedsYou | questions | {:list, {:text, 64}, 4} | [] |
| NeedsYou | options | :count | 0 |

Value changes on existing keys (same key, same type): the interaction "deadline" is the ask's real deadline in unix ms (0 = no clock) instead of a literal 0; needs_you "requested_at" is unix ms for questions (it was microseconds); a question option's "label" no longer carries its description, which travels in "description". The settings lane adds no wire key. Nobody appends to this table after task 100.
