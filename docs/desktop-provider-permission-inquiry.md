# Desktop quota-reader permission inquiry

Status: historical unsent draft from the pre-release investigation. This is not
the current release status or user guide, and it is not an outgoing request.
The opt-in Desktop connection shipped in 0.1.10. See the current
[connection guide](user-guide.md#claude-desktop-connection),
[privacy policy](../PRIVACY.md#opt-in-claude-desktop-connection) and
[research decision history](claude-acquisition-research.md#release-scope-update-2026-10-03).
The draft below is retained as historical research, not as evidence of a reply.

## Historical draft

Suggested subject: Permission for a local, read-only Claude Desktop quota viewer

QuotaTempo is an independent macOS menu-bar application that helps users plan
their weekly AI allowance. We would like to confirm an acceptable way to support
users who are signed in only to the official Claude Desktop application.

The proposed optional integration would, with explicit user consent:

- Read the currently selected account/organization and an unexpired access token
  from the user's own local Claude Desktop storage inside the local application.
- Call only `GET https://api.anthropic.com/api/oauth/profile` to verify ownership
  and `GET https://api.anthropic.com/api/oauth/usage` to obtain utilization and
  reset timestamps, no more often than every five minutes after success.
- Keep credentials in process memory only, with no third-party relay, logging,
  credential export, refresh-token use, token renewal, or changes to Desktop's
  authentication stores. Authentication renewal remains with Claude Desktop.
- Respect authentication failures and rate limits, and show unavailable data
  instead of inferring a new reset timestamp.

We understand that published authentication policy restricts third-party
intermediation of Claude account credentials. We do not treat other quota
viewers' implementations as permission.

1. Is this specific local, read-only quota use permitted, and if so under what
   written conditions or approval process?
2. If it is not permitted, is there an approved quota-only interface that
   supplies subscription utilization, exact reset timestamps, and account
   ownership to a local application without a separate Claude Code sign-in?

At the time of this draft, the integration had not shipped and public distribution
remained a separate decision. The isolated local diagnostic had a distinct
owner-authorized experiment mode; it did not set `providerApproved` or enable a
shipped application path.

Official inquiry route: the authentication-use section of
[Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)
links to [Contact sales](https://www.anthropic.com/contact-sales).
