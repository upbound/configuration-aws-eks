"""
    Brownfield import test suite.

    Validates the import lifecycle driven from spec.parameters.import:
      - observe:  external-name pinned, managementPolicies forced to observe-only,
                  and status.import drift report computed from observed atProvider.
      - missing:  a non-empty import.resources that omits required keys blocks the
                  render and reports status.import.missing + error.
      - commit:   import.commit=true switches managementPolicies to ["*"] while the
                  external-name stays pinned.

    The composite (EKS) status assertions use plain dicts because `import` is a KCL
    keyword and cannot be a schema attribute identifier.
"""

import models.io.upbound.awsm.eks.v1beta1 as eksv1beta1
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1

_common = {
    compositionPath = "apis/eks/composition.yaml"
    xrdPath = "apis/eks/definition.yaml"
    timeoutSeconds = 60
    validate = False
}

# --- observe phase: pin external-name, observe-only, and detect version drift ---
# XR wants version 1.34; the live cluster reports 1.33 -> one drift entry.
_observedCluster = eksv1beta1.Cluster {
    metadata = {
        annotations = {
            "crossplane.io/composition-resource-name" = "kubernetesCluster"
        }
        name = "imported-eks-cluster"
        namespace = "default"
    }
    spec = {
        forProvider = {
            region = "us-west-2"
            # Desired version (composition renders params.version into forProvider);
            # the live cluster is a minor behind -> reconcilable drift.
            version = "1.34"
            # Desired tags = the provider-injected crossplane-* defaults (the
            # composition itself sets no tags on the cluster).
            tags = {
                "crossplane-kind" = "cluster.eks.aws.m.upbound.io"
                "crossplane-name" = "imported-eks-cluster"
                "crossplane-providerconfig" = "default"
            }
            vpcConfig = {
                endpointPrivateAccess = True
            }
        }
    }
    status = {
        atProvider = {
            version = "1.33"
            accessConfig = {
                authenticationMode = "API_AND_CONFIG_MAP"
            }
            # Live tags come from the out-of-band tool (e.g. eksctl); committing
            # would strip these (2 removes) and add the 3 crossplane-* tags.
            tags = {
                "Name" = "eksctl-imported/ControlPlane"
                "alpha.eksctl.io/cluster-name" = "imported-eks-cluster"
            }
            vpcConfig = {
                endpointPrivateAccess = False
            }
        }
    }
}

_test_observe = metav1alpha1.CompositionTest {
    metadata.name = "import-observe-drift"
    spec = _common | {
        xrPath = "tests/test-eks-import/xr-observe.yaml"
        observedResources = [_observedCluster]
        assertResources = [
            # Cluster rendered observe-only with the external name pinned.
            eksv1beta1.Cluster {
                metadata = {
                    annotations = {
                        "crossplane.io/composition-resource-name" = "kubernetesCluster"
                        "crossplane.io/external-name" = "imported-eks-cluster"
                    }
                    # render assigns the observed resource's name to the desired resource
                    name = "imported-eks-cluster"
                    namespace = "default"
                }
                spec = {
                    managementPolicies = ["Observe", "LateInitialize"]
                    forProvider.region = "us-west-2"
                }
            }
            # Composite status.import shows the observe phase and the version drift.
            {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "EKS"
                metadata = {name = "imported-eks", namespace = "default"}
                status = {
                    "import" = {
                        active = True
                        commit = False
                        phase = "Observing"
                        missing = []
                        # Generic forProvider-vs-atProvider diff: version is the
                        # only reconcilable (param-backed) change.
                        driftCount = 1
                        # 2 eksctl tags removed + 3 crossplane-* tags added +
                        # endpointPrivateAccess false->true = 6 non-reconcilable
                        # changes committing would make beyond reconcilable drift.
                        sideEffectCount = 6
                        resources = {
                            kubernetesCluster = {
                                externalName = "imported-eks-cluster"
                                observed = True
                                drift = [{field = "version", desired = "1.34", observed = "1.33"}]
                            }
                        }
                    }
                }
            }
        ]
    }
}

# --- missing keys: render blocked, missing list + error surfaced ---
_test_missing = metav1alpha1.CompositionTest {
    metadata.name = "import-missing-blocks-render"
    spec = _common | {
        xrPath = "tests/test-eks-import/xr-missing.yaml"
        assertResources = [
            {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "EKS"
                metadata = {name = "imported-eks", namespace = "default"}
                status = {
                    "import" = {
                        active = True
                        commit = False
                        phase = "Observing"
                        missing = [
                            "ebsCSIDriverRole"
                            "kubernetesCluster"
                            "nodeGroupPublic"
                            "vpcCniAddon"
                            "ebsCsiAddon"
                            "podIdentityAgentAddon"
                            "ebsCSIDriverPodIdentityAssociation"
                        ]
                        error = "import.resources is set but required external names are missing; render blocked until all are provided"
                    }
                }
            }
        ]
    }
}

# --- commit phase: full management, external-name still pinned ---
_test_commit = metav1alpha1.CompositionTest {
    metadata.name = "import-commit-takes-management"
    spec = _common | {
        xrPath = "tests/test-eks-import/xr-commit.yaml"
        assertResources = [
            eksv1beta1.Cluster {
                metadata.annotations = {
                    "crossplane.io/composition-resource-name" = "kubernetesCluster"
                    "crossplane.io/external-name" = "imported-eks-cluster"
                }
                spec = {
                    managementPolicies = ["*"]
                    forProvider.region = "us-west-2"
                }
            }
            {
                apiVersion = "aws.platform.upbound.io/v1alpha1"
                kind = "EKS"
                metadata = {name = "imported-eks", namespace = "default"}
                status = {
                    "import" = {
                        active = True
                        commit = True
                        phase = "Committing"
                    }
                }
            }
        ]
    }
}

items = [_test_observe, _test_missing, _test_commit]
