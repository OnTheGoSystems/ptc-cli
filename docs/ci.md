# CI

For teams that want the translations delivered as merge requests from their CI.

Before delivering, PTC asks whether you want the translations as a merge request (PTC set up in your CI) or via the API. This page describes the merge-request route. The API route is the other answer; the CLI's download step is `--action download` (see [CLI reference](cli.md#workflow)).

Answer the merge-request route and PTC hands your agent the CI file with that
answer; the agent adds it to your repository. No separate prompt is needed.
`ptc init` prints the same jobs.

**Pin the CLI** to a release tag (`v1.5.7`), or use the floating `v1` tag (always
the newest published CLI).

### GitHub Actions

Add `PTC_API_TOKEN` (your agent token, from PTC's agent token page) to the repository secrets and turn on "Allow GitHub Actions
to create and approve pull requests" (Settings -> Actions -> General -> Workflow
permissions). The job runs through
[`ptc-action`](https://github.com/OnTheGoSystems/ptc-action), which vendors a
pinned copy of the CLI:

```yaml
name: PTC Translations
on:
  push:
    branches: [main]
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write
  id-token: write   # proves to PTC that this CI ran the commit

jobs:
  translate:
    runs-on: ubuntu-latest
    timeout-minutes: 180
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2   # lets the run name the files its commit changed
      - uses: OnTheGoSystems/ptc-action@v1
        with:
          api-token: ${{ secrets.PTC_API_TOKEN }}
          config-file: .ptc-config.yml
          create-pr: true
```

### GitLab CI

There is no GitLab component (`include: component:` resolves on your own
instance). `ptc init` prints a self-contained `ptc-translate` job: `alpine:3.22`,
`timeout: 3h`, an `id_tokens: PTC_ID_TOKEN` with `aud: ptc`, and a rule that runs
it only on a push to the default branch whose message lacks
`[skip translations]`. Its script:

1. installs `bash curl git unzip python3` and downloads the pinned CLI to `/tmp/ptc-cli.sh` (outside the checkout; `PTC_CLI_URL` overrides the URL);
2. runs `guide action-run`, then `guide check --json` and `guide mr-description`;
3. runs the translation with `--written-manifest /tmp/ptc-written`, continuing on exit `5`, `6` or `7`;
4. stages exactly the manifest's files on `ptc/translations`, commits `chore(i18n): update translations via PTC [skip translations]`, pushes with `-o merge_request.create` and reports `guide delivery-commit` (with `--stopped-reason monitor_bound` on exit `7`);
5. fails the job on `5`, `6` or `7` with the reason, after delivery.

Exit `7` means the run stopped at its time bound while PTC was still translating; nothing failed. Once PTC finishes,
re-run the job with one click: GitLab "Retry this job", GitHub "Re-run failed jobs". The re-run keeps the run id (the
pipeline / run id), so PTC translates nothing again, and it keeps every file the first job delivered: a file is skipped
only when its outputs are on disk with the sha that run wrote, otherwise it is downloaded again into the fresh checkout.
The translations merge request or pull request grows run by run until done.

Store `PTC_API_TOKEN` as a **masked** CI/CD variable. The push needs a token
that may write to the repository: `CI_JOB_TOKEN` can, only if a maintainer
enables Settings -> CI/CD -> Job token permissions -> "Allow Git push requests
to the repository" (GitLab 18.4+, off by default). Otherwise set
`PTC_GIT_PUSH_TOKEN` to a project access token with `write_repository` scope,
also masked.
