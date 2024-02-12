# AWS EKS Configuration

This repository contains a [Crossplane configuration](https://docs.crossplane.io/latest/concepts/packages/#configuration-packages), tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/) instances, leveraging the robust capabilities of the [Upbound Official AWS Provider](https://marketplace.upbound.io/providers/upbound/provider-family-aws).

## Overview

The core components of a custom API in [Crossplane](https://docs.crossplane.io/latest/getting-started/introduction/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Implements the API by orchestrating a set of Crossplane managed resources.

In this configuration, the EKS API contains:

- **an [EKS](/apis/definition.yaml) custom resource type.**
- **Composition of the EKS resources:** Configured in [/apis/composition.yaml](/apis/composition.yaml), it provisions an EKS cluster and fundamental security and networking resources in the `upbound-system` namespace.

## Deployment

To deploy this configuration into a new Crossplane installation, use the `--set configuration.packages` flag in your `helm install` command.

```shell
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: configuration-aws-eks
spec:
  package: xpkg.upbound.io/upbound/configuration-aws-eks:v0.7.0
```

## Next steps

This repository serves as a foundational step. To enhance your control plane, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs


Upbound will automatically detect the commits you make in your repo and build the configuration package for you. To learn more about how to build APIs for your managed control planes in Upbound, read the guide on Upbound's docs.
