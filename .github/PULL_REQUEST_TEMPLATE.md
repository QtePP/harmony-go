## What changed

<!-- Behavior, not files. -->

## Why

<!-- Root cause / user-visible problem. -->

## Verification

- [ ] `devecocli check arkts <changed files>` — 0 errors
- [ ] `devecocli build`
- [ ] Device test (model/API, ACP or SDK, what you did)
- [ ] Payload test if `host/` changed (`bash scripts/test.sh unit`)

## Checklist

- [ ] Each commit has `Signed-off-by` (`git commit -s`)
- [ ] Protocol/architecture docs updated in the same commit when behavior changed
- [ ] No secrets, signing material, device serials or private conversation data
- [ ] Fork/third-party code has its license and attribution
