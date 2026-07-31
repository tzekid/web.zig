# Cross-consumer server-first reliability review

Status: accepted review gate

## Outcome

Evaluate the Cloudio, Sparkdate, and plosca.ru reliability implementations for
shared semantics without turning `web.zig` into a frontend framework or test
runner distribution.

## Candidates

| Candidate | Benefit | Cost |
| --- | --- | --- |
| Add UI lifecycle and Playwright abstractions now | Centralizes new work | Couples product DOM and test environments to the runtime library |
| Keep product behavior local; extract only identical pure checks | Preserves small ownership boundaries | Some intentional duplication |
| Add nothing and do not review | Zero library work | Repeated protocol bugs could diverge unnoticed |

## Decision

Apply the existing two-consumer extraction rule. Browser journeys, selectors,
fixtures, island lifecycle, and product state transitions remain in their
applications. A helper may be added only if two completed consumers need the
same pure protocol assertion and the shared API is smaller than both copies.

## Definition of done

- [ ] Completed consumer implementations are compared after their tests pass.
- [ ] No product selector, page model, browser dependency, client state, or
      lifecycle framework is added to `web.zig`.
- [ ] Any extracted helper has two named consumers, deterministic unit tests,
      and no application import.
- [ ] If no helper clears that bar, the documented no-extraction decision is
      the completed result.
- [ ] `zig build test` and the external consumer build pass.
