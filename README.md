# AWS EKS Configuration

This repository contains an Upbound project, tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/) instances.

## Overview

The core components of a custom API in [Upbound Project](https://docs.upbound.io/learn/control-plane-project/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Configures the Functions Pipeline
- **Embedded Function(s):** Encapsulates the Composition logic and implementation within a self-contained, reusable unit

In this specific configuration, the API contains:

- **an [AWS EKS](/apis/eks/definition.yaml) custom resource type.**
- **Composition:** Configured in [/apis/eks/composition.yaml](/apis/eks/composition.yaml)
- **Embedded Function:** The Composition logic is encapsulated within [embedded function](/functions/eks/main.k)

## Deployment

- Execute `up project run`
- Alternatively, install the Configuration from the [Upbound Marketplace](https://marketplace.upbound.io/configurations/upbound/configuration-aws-eks)
- Check [examples](/examples/) for example XR(Composite Resource)

## Testing

The configuration can be tested using:

- `up composition render --xrd=apis/eks/definition.yaml apis/eks/composition.yaml examples/eks/eks-xr.yaml` to render the composition
- `up test run tests/*` to run composition tests in `tests/test-eks/`
- `up test run tests/* --e2e` to run end-to-end tests in `tests/e2etest-eks/`

## Brownfield import

EKS clusters that already exist in AWS (created via the console, Terraform, `eksctl`, etc.) can be
adopted by this composition **without recreating or mutating them**, using the `import` block on the
`EKS` XR (see [examples/eks/eks-import-xr.yaml](/examples/eks/eks-import-xr.yaml)).

### How it works

1. **Observe** — set `spec.parameters.import.resources` to a map of composition resource key →
   `crossplane.io/external-name` of the existing AWS resource, with `import.commit: false`. Every managed
   resource is rendered **observe-only** (`["Observe","LateInitialize"]`) and pinned to the given external
   name, so nothing in AWS is changed. The composition publishes a report on `status.import` that is a
   **generic diff of each resource's `spec.forProvider` (the composition's desired state, the source of
   truth) against its live `status.atProvider`** — i.e. everything committing *would* change. There is no
   curated field list; any field the composition declares that the cloud disagrees with shows up. Each
   change is classified (see below) into `drift` (reconcilable via parameters) and `sideEffects`
   (everything else), with `driftCount` and `sideEffectCount` totals.
2. **Reconcile** — adjust `spec.parameters` (version, instance type, subnets, ...) until
   `status.import.driftCount` is `0` (or covers only changes you intend to apply), then **review
   `status.import.sideEffects`**: these are changes with no parameter knob that committing will make anyway
   (tag rewrites, role policies, addon config, ...). Accept them before continuing.
3. **Commit** — set `import.commit: true`. Management policies switch to `["*"]`, taking full control and
   converging the mutable configuration to what the composition declares. The provider **refuses any change
   that would require replacing a resource** (its built-in guardrail), so immutable / create-time fields are
   protected — you do not have to predict them.
4. **Finalize** — remove the `import` block. The external names persist on the managed resources, so the
   cluster stays adopted under normal management. Keep `spec.parameters.network` (see below) — it is a
   normal parameter, not part of import.

If `import.resources` is non-empty but any importable resource the composition would render is missing an
external name, the render is **blocked** (no managed resources are emitted) and `status.import.missing`
lists the missing keys — a guardrail against a half-imported, half-created state.

### The report: `drift` vs `sideEffects`

`status.import.resources.<key>` carries two lists, both produced by the same generic `forProvider` ↔
`atProvider` diff:

- **`drift`** (summed into `driftCount`) — changes backed by an editable XR parameter, so you can
  reconcile them to zero before committing: currently `version`, `accessConfig.authenticationMode`,
  node `instanceTypes`, `scalingConfig.desiredSize`, and `subnetIds`. Each entry is
  `{field, desired, observed}`.
- **`sideEffects`** (summed into `sideEffectCount`) — everything else the diff finds: changes committing
  will make that you **cannot** influence through parameters. These are informational but important; review
  them before setting `commit: true`. Common ones:
  - **Tag rewrites.** The provider reconciles each resource's tag set to `forProvider`, which is the
    auto-injected `crossplane-*` management tags. Tags the original tool added (e.g. `eksctl` /
    cost-allocation tags) are **removed** on commit (shown as an entry with only `observed`), and the
    `crossplane-*` tags are **added** (shown with only `desired`). Reported per key as `tags[<key>]`.
  - **IAM role policies / trust** (`managedPolicyArns`, `assumeRolePolicy`) — the composition declares its
    own role shape; committing conforms the adopted role to it, which may add/remove managed policies or
    rewrite the trust relationship.
  - **Addon `configurationValues`**, **`vpcConfig.endpointPrivateAccess`**, and any other field the
    composition fixes unconditionally.

Scalar lists (subnet IDs, policy ARNs, ...) are compared **order-insensitively**, so a cloud that returns
the same set in a different order does not register as a change. A `sideEffects` entry for an *immutable*
field is a change the provider will **refuse** at commit (its refuse-to-replace guardrail) rather than
apply — the report does not try to predict which fields those are.

### Existing / remote network (`spec.parameters.network`)

By default the composition selects subnets from a `Network` it composes (label-based, greenfield). A
brownfield cluster lives in a VPC the composition did not create, so you must tell it the real subnets via
`spec.parameters.network`:

- `subnetIds` — the cluster control-plane ENI subnets (should span ≥2 AZs).
- `nodeSubnetIds` — the worker-node subnets (defaults to `subnetIds`). **Node group subnets are immutable**,
  so these must match the existing node group exactly or commit will (correctly) refuse to replace it.

This is also the mechanism for running greenfield in a pre-existing VPC. The VPC is derived from the subnets
and the EKS cluster security group is managed automatically, so neither needs to be supplied.

### External-name formats

The cluster name for NodeGroup and PodIdentityAssociation comes from the composition's
`clusterNameSelector`, so their external-name is the **child id only** — do not prefix the cluster name.

| Key | AWS resource | external-name format |
|-----|--------------|----------------------|
| `kubernetesCluster` | EKS Cluster | `<cluster-name>` |
| `controlplaneRole`, `nodegroupRole`, `ebsCSIDriverRole` | IAM Role | `<role-name>` |
| `nodeGroupPublic` | EKS NodeGroup | `<nodegroup-name>` |
| `vpcCniAddon`, `ebsCsiAddon`, `podIdentityAgentAddon` | EKS Addon | `<cluster-name>:<addon-name>` |
| `ebsCSIDriverPodIdentityAssociation` | EKS PodIdentityAssociation | `<association-id>` (e.g. `a-xxxxxxxxxxxxxxxxx`) |
| `accessEntry` | EKS AccessEntry | `<cluster-name>:<principal-arn>` |
| `accessPolicyAssociation` | EKS AccessPolicyAssociation | `<cluster-name>#<principal-arn>#<policy-arn>` |

`accessEntry`/`accessPolicyAssociation` are only required when `spec.parameters.iam.principalArn` is set.

### Notes / boundaries

- **ClusterAuth** is a token generator with no importable external state; it always runs under normal
  management (`["*"]`) even during import.
- **Create-time-only fields** (e.g. `bootstrapSelfManagedAddons`) cannot be changed on an adopted cluster
  without recreating it. The composition does not try to conform them; the provider's refuse-to-replace
  guardrail protects the resource and surfaces a benign condition. Adopt for day-2 management, not for
  re-architecting immutable topology.

## Next steps

This repository serves as a foundational step. To enhance your configuration, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs

To learn more about how to build APIs for your managed control planes in Upbound, read the guide on [Upbound's docs](https://docs.upbound.io/).