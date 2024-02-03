# Crossplane AWS EKS Configuration

This repository contains a [Crossplane configuration](https://docs.crossplane.io/v1.11/concepts/packages/#configuration-packages), tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/) instances, leveraging the robust capabilities of the [Upbound Official AWS Provider](https://marketplace.upbound.io/providers/upbound/provider-family-aws).

## Overview

The core components of a custom API in [Crossplane](https://docs.crossplane.io/v1.11/getting-started/introduction/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Implements the API by orchestrating a set of Crossplane managed resources.

In this configuration, the EKS API contains:

- **an [EKS](/apis/definition.yaml) custom resource type.**
- **Composition of the EKS resources:** Configured in [/apis/composition.yaml](/apis/composition.yaml), it provisions an EKS cluster and fundamental security and networking resources in the `upbound-system` namespace.

This repository contains an Composite Resource (XR) file.

## Next steps

This repository serves as a foundational step. To enhance your control plane, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs


Upbound will automatically detect the commits you make in your repo and build the configuration package for you. To learn more about how to build APIs for your managed control planes in Upbound, read the guide on Upbound's docs.
