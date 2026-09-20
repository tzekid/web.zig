# web.zig simplification plan

Planning snapshot: 2026-09-04. Implementation and qualification: 2026-09-05.

## Current state and evidence

- Local `ecosystem` is `4c53178`; recorded `origin/master` is `d30e4cb`, with four local and one default unique commits. Default is a small collection of standalone server-rendering/HTTP modules. Local adds `web_app`, digest and umbrella modules, route validation, HTML attribute validation, and lifecycle/load tests.
- dbui is a real consumer of the local `web_app.App` and `RequestContext`, using one worker, queue depth eight, one request per connection, and its own health route. Default does not export that module. It would be unsafe to discard the branch and simply repoint dbui at default.
- The local umbrella test imports every module, while the build also creates tests per module and integration test roots. This is a candidate for repeated execution, to confirm from actual build/test summaries.
- `tools/consumer-check.sh` tries to build plosca.ru as a Zig consumer even though that site is now authored static HTML. The package `.paths` excludes tests, although the build advertises test/consumer steps that reference them.
- `tests/load.zig` imposes a fixed 200 requests/second and Linux `/proc` RSS ceiling. It also contains useful real-listener behavior. These are different kinds of evidence; fixed host-speed policy is not a portable correctness contract.

## Intended result

Keep small standalone modules, preserve the lifecycle API already used by dbui, and publish a reproducible package with tests that prove behavior. Remove stale consumer checks and repeated/policy-only gates. Do not require every application to adopt web_app, the umbrella module, HTMX, or shared digest helpers.

## Implementation sequence

1. Refresh refs and preserve the local implementation in a recoverable ref. Start an isolated integration checkout from current default and selectively retain the used `web_app` surface and its direct prerequisites. Do not promote the umbrella/digest modules just to simplify them afterward: no inspected application imports the umbrella, and Nob's plan retains its standalone digest implementation. Keep current default's compiler pin; adapt only genuine incompatibilities and qualify the result. dbui's plan freezes its known compatible source first, so this work does not require a simultaneous production dependency change.
2. Retain the local HTML attribute-name validation and its ReleaseFast rejection/no-partial-write check: replacing assertions with a real error prevents malformed output when assertions are disabled. Preserve route validation required by routed lifecycle code. Review API/error-set changes against real consumers; do not rename public exports for cosmetic consistency.
3. Keep lifecycle worker bounds, connection ownership, graceful drain, forced-close behavior, and existing optional job interfaces intact during this cleanup. The implementation uses Linux operations and process-global signal state: explicitly bound the new lifecycle API to Linux and one active App per process, with early rejection of a second runner, rather than implying portable multi-server support. Keep independent HTML/request modules usable without that runtime. dbui's one-request-per-connection setting prevents its single worker from blocking asset requests behind idle browser connections; do not change that consumer policy to simplify a generic keep-alive test.
4. Give each module's focused tests one owner, confirming execution from the selected integration branch. Do not claim the unpromoted umbrella traversal as savings from current default CI. Remove assertions in `tests/first_view.zig` that merely verify its fixture's own literal project names/form attributes; retain distinct module-composition coverage only where it exercises real library behavior. Actual native form acceptance belongs to the real application journey. Keep listener and ReleaseFast security coverage.
5. Replace the obsolete plosca.ru consumer script with the existing standalone packaged consumer and a disposable dbui integration run. Preserve module identities and package export paths, including the files required by advertised test/build steps. Do not scan or copy every sibling checkout, and do not add a consumer framework.
6. Convert the load journey's correctness portion into a bounded real-listener scenario: expected bodies/counts, concurrent progress, keep-alive where supported, queue saturation, and shutdown. Remove uncalibrated throughput/RSS thresholds from mandatory correctness gates. Keep optional performance measurements descriptive and explicitly Linux-specific where `/proc` is used. Remove copied test-count and warn-only hygiene floor requirements; keep one actual CI workflow.

## Verification and delivery

- Run module tests, focused ReleaseFast HTML validation, any retained distinct rendering integration, Linux lifecycle behavior, and the external packaged consumer with the exact selected compiler. Verify the package in a fresh temporary location with no sibling checkout dependency; test actual exported artifacts rather than an in-tree path-only build. A second App must fail without altering the running instance's listener/signals, and a subsequent App must start after clean shutdown.
- Exercise the current dbui source in a disposable checkout against the candidate, preserving its connection settings and request context. Run its existing HTTP/SQL/file recovery acceptance with fixture databases. Do not edit dbui's real pin, files, configuration, or service during library qualification.
- Ensure queue saturation, idle-connection shutdown, stalled-read drain deadlines, and periodic-job shutdown retain meaningful coverage. All test threads/processes must terminate on setup failure as well as success. Report performance only for the measured environment, without an invented universal floor.
- Review package completeness, public API/type identity, consumer configuration, test duplication, and shutdown failure paths adversarially; repair findings and repeat until a complete pass has no new or unresolved blockers. Push only reviewed changes to `master`, verify remote revision and applicable CI, and leave local experimental work recoverable.
- No service deployment or automatic tag/release publication. Applications adopt the resulting immutable library version separately after their own relevant acceptance checks.

## Planning review

- Pass 1 found that dropping the local lifecycle would break dbui, that its one-request connection policy differs deliberately from the library load fixture, and that the runtime has Linux/process-global signal constraints. The plan preserves the consumer and makes those limits explicit. Review also identified fixture-literal first-view assertions and the obsolete plosca.ru consumer target rather than classifying all test imports as redundant.
- Pass 2 checked dbui's actual options, app initialization/shutdown, routed prerequisites, attribute validation, package paths, and load-test behavior. No unresolved or new planning blockers were found. Promotion requires real compatibility qualification; the plan does not claim it is already tested on the newer compiler or portable across operating systems.
- Cross-project review found that promoting the unused umbrella/digest would add work solely to remove its test overhead. The plan now leaves those experiments unpromoted, consistent with Nob's standalone design. A final review of the selected exports, dbui snapshot boundary, and branch-specific test claims found no further planning blockers.


## Implementation and adversarial review

- Started from default `d30e4cb` in an isolated worktree, preserving `ecosystem` at `4c53178`. Selected only `web_app` and its HTML/router prerequisites. Kept the default compiler and standalone module identities; the digest/umbrella experiments, obsolete sibling consumer script, and floor tooling were never promoted.
- Published the Linux lifecycle used by dbui with explicit process ownership and one run attempt per instance. An inactive App cannot stop another App. Signal handlers are restored; listener closure waits for any signal handler already using its descriptor. Socket registration, queued/in-flight transfer, forced shutdown, and final close share one mutex so descriptors cannot be reused while still registered.
- Corrected startup cleanup to join jobs as well as workers. Drain now measures elapsed time rather than counting condition wakeups; queued work cannot start a new handler after force-close. Documented the actual idle-timeout boundary and cooperative/bounded handler/job contract.
- Retained module tests and added ten lifecycle scenarios, one focused ReleaseFast attribute rejection check, and a bounded four-client/eighty-response keep-alive journey. All fixtures own their server/client threads on failure. CI bounds the complete processes; no throughput or RSS threshold is a correctness gate.
- Removed `first_view.zig`'s fixture assertions. The external consumer now verifies escaping, captured route parameters, and method rejection, and receives the selected optimization mode. The package script exports only declared source inputs and exercises them outside the checkout. Explicit nested-consumer paths prevent its build cache entering the package.

### Review findings and verification

1. Review found process-global shutdown interference, jobs left alive on partial startup, wake-count drain timing, descriptor lifetime gaps, and queued handlers starting after forced shutdown. Corrected each; preserved queue rejection, keep-alive reuse, health, routed dispatch, periodic jobs, idle/partial-header shutdown, and stalled-body behavior.
2. Real-listener negative checks reproduced the failures: restoring wake-count timing yields `ForcedShutdown` within the grace period; removing instance ownership makes the active listener refuse its next connection. The corrected implementation passes both journeys. Startup-concurrency rejection also returns after its worker/job threads stop.
3. Export review found a nested consumer build cache in the initial broad `tests` export and a renamed consumer's fingerprint mismatch. Corrected source paths/fingerprint and the compiler's tar archive extraction. Increased CI's process limit after a cold compilation exceeded three minutes; it remains a hang bound, not a performance floor.
4. Disposable dbui at `0c0c5b0` passed ReleaseSafe focused tests, HTTP/SQL/file acceptance, and all eight browser recovery groups (8/8 build steps) against the candidate. Verified its qualified runtime and HTML/router bytes still match the final candidate. The real dbui pin, source, configuration, data, and service are unchanged.

5. A full exported run exposed an intermittent `NeverSaturated` fixture failure. Reproduced it directly: a fill-buffer read discarded the already-received overload bytes when the peer reset afterward. The fixture now retains chunks and checks one complete 503/Retry-After/body response after establishing the held worker and queued connection. Removed its 200-attempt retry loop; the targeted ReleaseSafe check passed 100 consecutive executions.

6. Final exported package `web-0.1.0-dev-_XMZo6IXAgDUfKTketXqq2Z27ss13uGVombbzhXRccxj` passed 30/30 build steps and 46/46 tests, including the external consumer in ReleaseSafe. The final Debug graph also passed all 30 steps. Formatting, shell syntax, and diff checks passed.
7. The complete final pass rechecked process/signal ownership, partial-start cleanup, fd registration/close ordering, real deadline accounting, queued forced-stop behavior, fixture termination, exported source completeness, optimization propagation, default-versus-experimental scope, and the dbui boundary. No unresolved or new implementation blockers remained. Library adoption remains an application decision; no service deployment or tag is part of this change.

## Follow-up: 2026-09-20

### Current facts, scope and acceptance

Default `e011001` pins Zig2085 and has successful CI34394105815. The historical
`ecosystem` checkout4c53178 and its untracked plan remain intact. Current dbui
has its separately qualified frozen snapshot/local patch at3a28a45; publication
here must not replace that pin or touch its service, configuration or data.

A real App with100ms idle timeout still holds an incomplete header after350ms:
the initial readable gate does not bound subsequent blocking socket calls. The
standalone reproduction fails against current default. Fix this actual gap,
without changing standalone modules, public handler types or process ownership.

1. Reuse `idle_timeout_ms` as a cumulative per-request socket I/O budget, with
   monotonic deadlines and nonblocking Linux syscalls. Zero remains unlimited.
   Preserve a separate initial/keep-alive idle wait, parser buffers, fresh budget
   per request, and handler time between socket calls. Do not impose a whole
   handler wall-clock limit or add a libc requirement. Make overload response
   delivery nonblocking so the accept loop retains its immediate-rejection
   contract; it cannot guarantee delivery to a broken/non-reading peer.
2. Add bounded real-socket stalled-head/body/trickle recovery, slow-reader and
   delayed-handler acceptance. Keep zero timeout, pipelined and ordinary
   keep-alive, queue saturation, owner/signal restoration, startup cleanup,
   drain deadline and queued forced-stop behavior. All test threads/FDs must
   unwind on failure; no throughput/RSS floor or repetitive retry matrix.
3. Run Debug module/concurrent/consumer graph, complete exported ReleaseSafe
   graph, and the existing focused ReleaseFast HTML rejection check. Verify
   source archive completeness and an external consumer without sibling inputs.
4. Qualify current dbui3a28a45 in a disposable copy against the exported
   candidate, running its real HTTP/SQL/file and eight browser recovery groups.
   Preserve its real frozen dependency and deployment; this is qualification,
   not adoption. Reuse fixture databases, never user data.
5. Require two complete clean implementation reviews after fixes. Commit/push
   default and verify exact hosted CI. Publish SDK source only; no service/tag,
   extra release framework or automatic consumer update is appropriate.

### Follow-up plan reviews

- Pass1, complete API/behavior review found that copying a whole-request
  wall-clock deadline would also cut off legitimate handler/provider work.
  Charge only socket-operation time, cumulatively across progress; separately
  bound idle waiting. Preserve zero disable and pipelining. The overload path
  uses blocking writes despite its immediate-return contract; include a direct
  nonblocking send without introducing an accept-loop wait. Reset clean count.
- Pass2, complete functional/security/lifetime perspective: traced current
  request buffers, connection ownership, drain/force-stop and signal lifetimes.
  Planned tests distinguish a stalled peer from long handler work and retain
  all existing lifecycle checks and Linux/no-libc boundary. Zero findings;
  clean1.
- Pass3, complete package/delivery/preservation perspective: checked current
  default/pins, experimental checkout, frozen dbui provenance, export paths,
  standalone consumer and exact workflow. Disposable acceptance and separate
  publication preserve the already-qualified application. Zero findings;
  clean2.

### Follow-up implementation reviews and qualification

- Pass1, complete failure/ownership review found that a timed-out body read
  entered the generic handler-error path, counted a client failure as a5xx and
  could continue keep-alive processing. The new real-socket assertion reproduced
  `expected0,found1`; transport read/write/EOF failures now return directly to
  connection teardown. The trickle fixture tolerates the expected peer-close
  race while sending its next byte. Reset clean-pass count to zero.
- Pass2, complete functional/security/lifetime review: verified cumulative
  monotonic accounting across EINTR/EAGAIN and partial I/O, separate bounded
  idle waiting, zero disable, fresh budgets on reuse, buffered pipelining and
  excluded handler time. Nonblocking overload delivery cannot park the accept
  loop. Existing single-owner/signal restoration, partial-start cleanup, real
  drain deadline and queued forced-stop tests remain intact. The original
  partial-header reproducer now passes; a blocking-send mutant fails promptly
  under an owned watchdog. Debug test/journeys/consumer graph passes30/30steps.
  Zero findings; clean1.
- Pass3, complete package/product/operational review: the complete exported
  ReleaseSafe graph passes30/30steps and49/49tests, including the always-
  ReleaseFast HTML rejection check, external consumer and four-client bounded
  keep-alive journey. Export27files/37620bytes contains no caches and all
  exported bytes match final source. Disposable current dbui3a28a45 passes
  8/8steps: HTTP/SQL/file acceptance, all eight browser recovery groups and
  stalled-head/body/trickle recovery with clean shutdown. Linux SDK tests link
  without libc. Original ecosystem/plan and real dbui frozen dependency,
  provenance, files and running service remain untouched. Zero findings;
  clean2. Publish source and verify exact CI; no application adoption is implied.
