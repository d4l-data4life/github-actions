# github-actions

This repository defines reusable github actions to help test, build and deploy our repositories.

## General Github Action Information

Action inputs are always strings, therefore "boolean" flags are also strings and compared as such.

For golang builds to work we need a github token that allows pulling from other private repos in the organization.
The automatic `GITHUB_TOKEN` that is provided to every github action is not sufficient.
Therefore we rely on having the organization wide secret `CI_USER_GITHUB_TOKEN` that is used for this purpose.

For our repos to be deployable to Azure we need the credentials of a technical user (in azure called service principal).
These credentials are stored in our repos individually as `AZURE_CI_CREDENTIALS`.
The secret value is a JSON and its source of truth is the azure keyvault `app-sensorhub-ci`.

Passing secrets to actions as input parameters still leads to them being masked in the logs, as long as they were defined secrets before being used as paramters.

For docker commands to work properly with the actions they need to use `docker buildx build` and get a few additional parameters:

```makefile
	docker buildx build \
		--cache-to type=gha,mode=max \
		--cache-from type=gha \
		--load \
		...
```

`--cache-*` enables the caching on github actions, without causing any problems locally (on my machine).
`--load` is required to expose the built image to the local `docker images`, so that it can be used after being created.
This is due to `buildx` using a different driver than the default docker one.

## Exposed Actions

### build-setup

Prepare the github runner for our build actions, configurable via input parameters.

Capabilities:

- sets up Github Action docker cache to cache docker like you would locally (with remote storage though)
- prepares a docker buildx build instance to be used
- [run-code-gen] run protobuf code generation via `make generate`
- [setup-go] run setup-go to install the required go environment an enable go mod and go build caching
- [setup-node] run setup-node to install the node environment and run `npm ci` (with caching enabled)
- [setup-yarn] run setup-node to install the node environment and run `yarn install` (with caching enabled)
- [acr-login] login to azure container registry to push our images

| Inputs            | Required  | Default | Description                                                                |
| ----------------- | --------- | ------- | -------------------------------------------------------------------------- |
| run-code-gen      | false     | false   | Run protobuf code generation                                               |
| setup-go          | false     | false   | Run (setup-go)[https://github.com/actions/setup-go]                        |
| setup-node        | false     | false   | Run (setup-node)[https://github.com/actions/setup-node] and `npm ci`       |
| setup-yarn        | false     | false   | Run (setup-node)[https://github.com/actions/setup-node] and `yarn install` |
| acr-login         | false     | false   | Login to ACR using azure ci user credentials                               |
| azure-credentials | acr-login | "{}"    | Credentials for azure cli login in JSON format                             |

Use at beginning of build job after checkout and configure as needed:

```YAML
- uses: actions/checkout@v3
- uses: gesundheitscloud/github-actions/build-setup@main
  with:
    run-code-gen: 'true'
    setup-go: 'true'
    acr-login: 'true'
    azure-credentials: ${{ secrets.AZURE_CI_CREDENTIALS }}
```

### database

Creates/Updates a postgres database including login user for the given repository.

Capabilities:

- fetch postgres admin credentials from keyvault `<environment>--db--postgres--admin`
- database configuration for the repository is also read from keyvault `<environment>--db--<repository>`
  - JSON value that has to be created manually
  - Properties: `DBName`, `Hostname`, `Port`, `password`, `username`
- runs `database.sh` script to `create`/`update`

| Inputs            | Required | Default   | Description                                      |
| ----------------- | -------- | --------- | ------------------------------------------------ |
| project           | true     | sensorhub | Project the action is used for                   |
| operation         | false    | create    | create/update (create fails when already exists) |
| environment       | false    | dev       | dev/staging/prod                                 |
| azure-credentials | true     |           | Credentials for azure cli login in JSON format   |

Use by creating a `.gihub/workflows/database.yaml`

```YAML
name: Database Creation

on:
  workflow_dispatch:
    inputs:
      operation:
        type: choice
        description: Operation
        default: create
        options:
        - create
        - update
      environment:
        type: choice
        description: Environment
        default: dev
        options:
          - dev
          - staging
          - prod

jobs:
  create:
    runs-on: ubuntu-latest
    steps:
      - uses: gesundheitscloud/github-actons/database@main
        with:
          project: sensorhub
          operation: ${{ inputs.operation }}
          azure-credentials: ${{ secrets.AZURE_CI_CREDENTIALS }}
          environment: ${{ inputs.environment }}
```

### deploy

Deploy service to AKS

Capabilities:

- login to Azure and get AKS credentials/config
- get required secrets from keyvault
  - db secrets `<environment>--db--<repository>`
  - common secrets `<environment>--common`
  - service secrets `<environment>--<repository>`
  - [airms] get TLS secrets `airms-<environment>-appgw-backend-cert`
- runs `make deploy`

:warning: All of these secrets have to exists, be in JSON form and contain at least one attribute.

| Inputs            | Required | Default   | Description                                      |
| ----------------- | -------- | --------- | ------------------------------------------------ |
| project           | true     | sensorhub | Project the action is used for                   |
| environment       | false    | dev       | dev/staging/prod                                 |
| azure-credentials | true     |           | Credentials for azure cli login in JSON format   |

Use by creating a `.gihub/workflows/deploy.yaml`

```YAML
name: Deploy

on:
  workflow_call:
    inputs:
      environment:
        type: string
        description: Environment (dev/stg/prod)
        default: dev
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        description: Environment
        default: dev
        options:
          - dev
          - staging
          - prod

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: gesundheitscloud/github-actions/deploy@main
        with:
          project: sensorhub
          environment: ${{ inputs.environment }}
          azure-credentials: ${{ secrets.AZURE_CI_CREDENTIALS }}
```
