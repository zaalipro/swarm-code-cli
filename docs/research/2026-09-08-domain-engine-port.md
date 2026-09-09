# Domain engine port

Source repository: `/Users/zaali/dev/swarm-code`; pinned revision: `fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`.

## Adaptations

- Mechanically prefix all `SwarmCode.` references with `SwarmCode.Domain.`.
- Replace Phoenix PubSub calls with `SwarmCode.Domain.PubSub`.
- Replace desktop notification calls with `SwarmCode.Domain.Notifications`.
- Rename the web format comment reference to `SwarmCode.Domain.Format` (Operation retains its existing internal UTF-8 window implementation).
- Resolve application configuration and bundled spec resources through `:swarm_code_daemon`.
- Preserve all upstream swarm, goals, plan, consensus, agent supervision, operation, question and persistence behavior. No runtime stubs introduced.

## Provenance

| Source path | Source SHA-256 | Destination path | Destination SHA-256 |
| --- | --- | --- | --- |
| `lib/swarm_code/engine.ex` | `4e63bda86051e57c3c5a360ebc6c4130ff4bd1607bb3bd13fdca07d33de87737` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine.ex` | `39ea497ee3e5fb8bf7eb2dcb5c24c3e3181f9e7168df1ce866e09fc742bc3bba` |
| `lib/swarm_code/engine/agent_server.ex` | `423fead00abd90f17885fa62871653431fca79a756bd1458a00447770dc4326e` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/agent_server.ex` | `20991e9e27f16497419d96428c83373aee73ed81ed1ce889b0ca37da9e77601c` |
| `lib/swarm_code/engine/agent_sup.ex` | `beb678238ec8ca1ccf4afcdbbad6baeb1f35379716bdc91a21b44876500e40f6` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/agent_sup.ex` | `14e0ab7b2545d1512db97561c52b12db0998ef19a55f72738b9a71fdf3fcbd20` |
| `lib/swarm_code/engine/agents_sup.ex` | `98f49d3bd6c068f9d356b7d9f35a9703b865e04006e75f82d665369e6ef556ca` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/agents_sup.ex` | `69946479e10b0209ea8be8b06b4bb825dc431c247879be621a4db5f79748a0ab` |
| `lib/swarm_code/engine/consensus.ex` | `8750cf7060b1fe8100dc9bb8563515c67d16b37e840e7d5c09cb5ca788023bb5` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/consensus.ex` | `b1235e1226ff7d87d87b367c009abceccb09453e22175b55cda1d54e862aadd3` |
| `lib/swarm_code/engine/context.ex` | `a03450498aa786a0a48e1037bac10e6c5eac9a764f8a4af10f69721533ccc44f` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/context.ex` | `3e469b92a3210c2ff644d9936df8759ac51da06a779614aaa9fb1967ac9cb917` |
| `lib/swarm_code/engine/events.ex` | `2815033d969cd7f7afab3b5f6e9d1c8a4a7b642a1c5675abbde9e01e28f990ff` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/events.ex` | `c0da5e9e06f78b9793f083375224ce40f323c78746c18ad4dc5f3ad1c997a7cb` |
| `lib/swarm_code/engine/operation.ex` | `0446290141ce6868e542e2a3eb2c386155d54c13b223a4d16f930f48ec6cc7e6` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/operation.ex` | `a1a1816db84fa3b958fc5e185ffd8e6d5590b5d087f621d7fcbaca7629fd1831` |
| `lib/swarm_code/engine/policy.ex` | `cd896ace2410e02cf34a6a5c336771ceb22594674b77fdc77b87ff2d48f7a174` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/policy.ex` | `24b20f2a2e9bb62598eec051330a7a1f121abec74fae8251642bf59c85797f35` |
| `lib/swarm_code/engine/project_context.ex` | `3b82379ac946ad1c8468f0178e0684719b5f69b7e0a8e7aee8f0ec4010d8889c` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/project_context.ex` | `c2daceff2033ffd08ce95c539a4ecd7288c480945a5193cfa3c0b03220d5aed9` |
| `lib/swarm_code/engine/prompts.ex` | `0dd0c73c5c81f92c96d9e9f9ab6514e8ec9e0b6e4fec8a60cf87449b6dd9bfd9` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/prompts.ex` | `c2d9d4332436a287cc18eaf98f0520486450e8c58003be3983b3a4c70fed9c69` |
| `lib/swarm_code/engine/questions.ex` | `18be8daa26addc0cc0fca0d76b1c697bb6694c224a97ff21de453a7791067461` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/questions.ex` | `47194d029a9f37f11d4428ef5c0fa3687050e601d2ed1e7783c22f7ad9357840` |
| `lib/swarm_code/engine/run_server/nodes.ex` | `6f0433ee60c88d035ad53ef70c28bd81b99b8319366ef6b6cca78b3f64e3748d` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_server/nodes.ex` | `f64f35c7a40d3852433f9e027d104ef0d3959cc29e1e5ae03daffcb268536ad2` |
| `lib/swarm_code/engine/run_server.ex` | `e513594132a05a5bf187e7ae4427c867894fb224ccd7fca9077783ecb2674479` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_server.ex` | `9f729da5d7d108ad93af18bc142cc3f13383df526857fc323308ca77a4ae165e` |
| `lib/swarm_code/engine/run_sup.ex` | `56e617a1206b0f6c0fa35e6baaccc79dd9d1a1c10c87f460711f6623c4f2270c` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_sup.ex` | `b61e3f522e5ad28285b168ba77a99d069aed01c226b4f787bc3d2c498c57fc0c` |
| `lib/swarm_code/engine/run_supervisor.ex` | `69a7d11cb39042ae93e6691ad9774abca7d59a207032425a01f8ca98cd8406f4` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_supervisor.ex` | `34c6663db997b30f360995e32223bfb972cb29af5e7fe1fbaa899cc6fc8b6893` |
| `lib/swarm_code/engine/spec_template.ex` | `66b69b062521712b2ba5c656dc5e8cdfc09676dfda0e61e1819a3acfead4928c` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/spec_template.ex` | `f2a1ccba515ec4f271b30e0fd54ad9a48e3bbf23afdea9d5b184449a5f8a3144` |
| `lib/swarm_code/engine/workflow_prompts.ex` | `30540ff09046bc9b22e438f9f764a695f0d884be99d7d54998db2efce5bce993` | `apps/swarm_code_daemon/lib/swarm_code/domain/engine/workflow_prompts.ex` | `17bc6850962af26c7391163f60baf4da7867e260b72ece2e51303f648587a9c4` |

## Focused verification

Adapted upstream pure `policy_test.exs`, `prompts_test.exs`, `context_test.exs` and `consensus_test.exs` into `apps/swarm_code_daemon/test/swarm_code/domain/engine/` using the same module namespacing. The prompts image-storage integration describe block is omitted from this pure subset. Root coordinates daemon integration coverage.

A Python verification compared every ported engine file with the pinned git blob after exactly the adaptations above: all 18 matched. No Mix, Elixir compiler, dependencies, or test commands were run by this worker; root runs coordinated validation.

TDD red/green execution was not feasible under the root instruction prohibiting test/compiler commands during this parallel port. These are regression tests adapted from upstream, not claimed as newly observed red/green results.
