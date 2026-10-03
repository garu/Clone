# GitHub Actions workflows

Rules for editing or reviewing any workflow in this directory.

## Always use the most recent major version of upstream actions

- Pin every `uses:` to the **latest major tag** of the action, e.g.
  `actions/checkout@v7`, not `@v4`.
- Pin to the major tag only (`@v7`), not to a minor/patch tag (`@v7.0.1`),
  so fixes within that major arrive without edits.
- Find the latest major before writing or approving a `uses:` line:

  ```bash
  gh api repos/<owner>/<action>/releases/latest --jq .tag_name
  ```

- When you add a new job, use the same latest major as the other jobs.
  Never copy an older version from an existing job.
- When reviewing a PR that adds or changes a `uses:` line, flag any action
  that is not on its latest major and recommend the bump.
- When you bump one action, bump it in **every** job in the file, so all
  jobs stay on the same version.

## Before bumping a major version

- Read the release notes for breaking changes (renamed inputs, changed
  outputs, new runtime).
- New majors often move to a newer Node runtime. Jobs that run inside a
  `container:` (the `linux` and `distro-matrix` jobs) use that runtime
  inside the container image, so check those jobs pass in CI.
- If a new major breaks a job and the fix is not simple, keep that one job
  on the previous major and add a YAML comment that says why, with a link
  to the upstream issue.
