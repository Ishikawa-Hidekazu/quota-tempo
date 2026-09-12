## Summary

- Describe the user-visible or maintenance change.
- Link the related issue or discussion when one exists.

## Verification

- [ ] `swift test`
- [ ] `swift build -c release`
- [ ] Relevant documentation or fixture output was checked.

## Safety and release boundary

- [ ] This change does not add credentials, tokens, cookies, prompts, transcripts, provider files, raw responses, private paths, or personal quota values.
- [ ] Provider and privacy boundaries remain fail-closed, or the boundary change is explained above.
- [ ] No ad-hoc build is presented as a signed or notarized public release.
