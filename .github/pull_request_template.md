## Validation

- [ ] The configuration PR workflow passes for every Helm strategy scenario.
- [ ] Operational documentation is updated when behavior or ownership changes.

## Progressive-delivery changes

Complete this section when enabling, changing or removing a progressive
strategy. Otherwise, mark the first item.

- [ ] This PR does not change an active progressive-delivery strategy.
- [ ] The currently running stable image matches the digest pinned in Git.
- [ ] First adoption changes only the strategy; it does not introduce a new
      digest or another pod-template change.
- [ ] Argo Rollouts, its CRDs and the Argo CD ownership rules are healthy.
- [ ] Stable and candidate capacity, compatibility and safe smoke tests have
      been confirmed.
- [ ] The promotion owner and abort/rollback commands are identified.
