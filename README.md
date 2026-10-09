# npm OIDC check

Check that npm trusted publishing accepts your workflow. Nothing is published.

For each package, the action exchanges the GitHub OIDC token for an npm token. `npm publish` makes the same exchange before it uploads. The exchange succeeds only when a trusted publisher on the package matches the run. The npm token is masked and thrown away.

## Usage

```yaml
jobs:
  npm-check:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    steps:
      - uses: mpyw/npm-oidc-check-action@v1
        with:
          packages: |
            @scope/pkg
            @scope/pkg-linux-x64
```

| Input | Default | Description |
| --- | --- | --- |
| `packages` | (required) | Package names. Separate them with newlines, spaces or commas. |
| `registry` | `https://registry.npmjs.org` | Registry URL. |

| Output | Description |
| --- | --- |
| `workflow-ref` | The `workflow_ref` claim of the OIDC token. npm checks its filename. |

The step fails if any package fails. The job summary lists the result for each package.

> [!IMPORTANT]
> **npm checks the workflow that the run started from.** It does not check the reusable workflow that runs `npm publish`. So run this action from the workflow file you registered on npmjs.com. A separate `check.yml` only tests `check.yml`.

## Check without publishing

Add a `check_only` input to each workflow that you registered. When it is set, run only the check, and skip everything else.

```yaml
on:
  workflow_dispatch:
    inputs:
      version:
        required: false
        type: string
      check_only:
        type: boolean
        default: false

jobs:
  npm-check:
    if: inputs.check_only
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    steps:
      - uses: mpyw/npm-oidc-check-action@v1
        with:
          packages: '@scope/pkg'

  publish:
    if: ${{ !inputs.check_only }}
    # ...
```

Then dispatch it:

```sh
gh workflow run release.yml -f check_only=true
```

> [!TIP]
> Jobs that `need` a skipped job are skipped too. So one `if` on the first job usually skips the whole release.

## Check before publishing

Some projects publish several packages in one run. A wrong trusted publisher can stop that run halfway. Put the check in front of the publish, and the run stops before anything is published.

```yaml
steps:
  - uses: mpyw/npm-oidc-check-action@v1
    with:
      packages: |
        @scope/pkg
        @scope/pkg-linux-x64
  - run: npm publish
```

## Notes

| Topic | Detail |
| --- | --- |
| Runners | Use GitHub-hosted runners. npm trusted publishing does not accept self-hosted ones. |
| Tools | The action uses `bash`, `curl` and `jq`. GitHub-hosted runners have all three. |
| `npm publish --dry-run` | It makes the exchange too. But a failed exchange is only a verbose log line. The dry run still succeeds. |

> [!WARNING]
> The npm token from the exchange can publish the package. The action masks it in the log and never uses it. It expires on its own after a short time.

## License

[MIT](LICENSE)
